require 'metaforce'
require 'metaforce/reporters/deploy_reporter'
require 'fileutils'

class SfOpticon::Environment < ActiveRecord::Base
  attr_reader :log, :config
  validates_uniqueness_of :name,
    :message => "This organization is already configured."
  attr_accessible :name,
    :host,
    :username,
    :password,
    :securitytoken,
    :production,
    :locked

  has_many :sf_objects
  has_one  :branch

  # Setup variables
  after_initialize do |env|
    @log = SfOpticon::Logger
    @config = SfOpticon::Settings.salesforce
  end

  ##
  # This method is called when an environment is first created. This allows
  # us to reach out and create the remote repository if needed, or the branch.
  # This will also clone the branch.
  after_create do
    # Validate salesforce credentials before creating anything remote.
    unless sforce.credentials_are_valid?
      raise "Could not login to Salesforce! Please verify credentials."
    end    

    if production
      # If we're a production environment then we need to create the remote
      # repository
      SfOpticon::Scm.adapter.create_remote_repository(name)
    end

    create_branch(name: production ? 'master' : name)
    snapshot

    # We ignore the actual metadata objects in salesforce unless this is
    # production. We do this because we want them to start at the same logical
    # place, as though the non-production environment was refreshed even if it
    # wasn't.
    if production
      sforce.retrieve :manifest => sforce.manifest(sf_objects),
        :extract_to => branch.local_path

      branch.ignore_package_xml
      branch.add_changes
      branch.commit("Initial push of production code")
      branch.push
    end
  end

  ##
  # Each call to sforce will reconfigure the metaforce client.
  def sforce
    SfOpticon::Salesforce.new(self)
  end

  ##
  # Locks the environment to prevent the changeset tool from making any
  # changes. This is necessary so that integration branches will have
  # a pristine head to work from
  def lock
    self.locked = true
    save!
  end

  ##
  # Unlocks the environment.
  def unlock
    self.locked = false
    save!
  end

  ##
  # Rebases our branch from production
  def integrate(src_env)
    branch.integrate(src_env)
  end

  ##
  # Deploys code changes to this environment.
  #
  # @param sf_objects [String] The list of sf_objects to deploy.
  # @param destructive [Boolean] True if this is a destructive changeset
  def deploy(sf_objects, destructive = false)
    staging_dir = if destructive
      stage_destructive(sf_objects)
    else
      stage_artifacts(sf_objects)
    end
    log.info { "Deploying artifacts staged in #{staging_dir} to #{name}"}

    sforce.client.deploy(File.join(staging_dir,'src'), { :run_all_tests => false })
    .on_complete { |job| log.info job.result }
    .on_error {|job| log.error { "Error: #{job.result.inspect}" } }
    .on_poll {|job| log.info "Polling..." }
    .perform
  end

  ##
  # Creates a destructive staging area.
  # The directory must follow this layout
  # src/
  #   package.xml <- Must be an empty manifest
  #   destructiveChanges.xml
  def stage_destructive(sf_objects)
    staging_dir = Dir.mktmpdir
    src_dir = File.join(staging_dir, 'src')
    Dir.mkdir src_dir
    log.info { "Creating destructive staging area at #{staging_dir}" }

    File.open(File.join(src_dir, 'package.xml'), 'w') do |f|
      f.write(sforce.manifest([]).to_xml)
    end

    File.open(File.join(src_dir, 'destructiveChanges.xml'), 'w') do |f|
      f.write(sforce.manifest(sf_objects).to_xml)
    end

    staging_dir
  end

  ##
  # Creates the staging area for a set of deployment artifacts.
  # The directory from which we deploy must follow this layout:
  # src/
  #   package.xml
  #   classes
  #   etc.
  def stage_artifacts(sf_objects)
    staging_dir = Dir.mktmpdir
    log.info { "Staging artifacts info #{staging_dir} for deployment." }

    # Create layout
    src_dir = File.join(staging_dir, 'src')
    sf_objects.collect {|o| o.dirname }.uniq.each do |dir|
      FileUtils.mkdir_p(File.join(src_dir, dir))
    end

    # Create the package manifest
    File.open(File.join(src_dir, 'package.xml'), 'w') do |f|
      f.puts(sforce.manifest(sf_objects).to_xml)
    end

    # Copy the files into staging
    sf_objects.each do |o|
      FileUtils.cp(o.fileset, File.join(src_dir, o.dirname))
    end

    staging_dir
  end

  ##
  # Removes all sf_objects (via delete_all to avoid instantiation cost), the
  # local repo directory, and itself. This does *not* remove any remote repos!
  def remove
    # We skip the instantiation and go straight to single
    # statement deletion
    sf_objects.delete_all

    # And we delete our remote branch
    unless production
      branch.delete_remote_branch
    end

    # Discard the org contents.
    begin
      FileUtils.remove_dir("#{SfOpticon::Settings.scm.local_path}/#{name}")
    rescue Errno::ENOENT
      # We pass if the directory is already gone
    end

    delete
  end

  # Create's a clean snapshot of all SF metadata related to the
  # configured types.
  def snapshot
    ## Env has to have it's current sf_objects wiped out
    log.info { "Deleting all sfobjects for #{name}" }
    sf_objects.delete_all

    SfOpticon::SfObject.transaction do
      sforce.gather_metadata.each do |o|
        sf_objects << SfOpticon::SfObject.create(o)
      end
      save!
    end
  end

  # Generates a changeset from the latest snapshot and the current
  # metadata information from Salesforce. This changeset is then
  # committed to both the database and the repository.
  #
  # Returns the changeset
  def changeset
    curr_snap = sforce.gather_metadata
    change_queue = SfOpticon::Changes::Diff.snap_diff(sf_objects, curr_snap)
    if change_queue.all_changes.size == 0
      log.info { "No changes detected in #{name}" }
      return
    end

    # We now have an array of objects that have been deleted, renamed, added,
    # or modified in the correct order. We will replay these changes into the
    # local repository and the database.

    # First we have to generate a manifest of the additions and modifications
    # to retrieve those new objects
    mods = [change_queue.additions, change_queue.modifications].flatten.map {|x| x.sf_object }

    # Retrieve the changes into a temporary directory
    dir = Dir.mktmpdir("changeset")
    sforce.retrieve(:manifest => sforce.manifest(mods), :extract_to => dir)

    # Now we replay the changes into the repo and the database
    change_queue.apply_change_queue(dir, branch.local_path) do |change|
      log.info { "DIFF: #{change.change_type} - #{change.sf_object[:full_name]}" }

      commit_message = "#{change.change_type} - #{change.sf_object[:full_name]}\n\n"
      if change.change_type == :deletion
        commit_message += "#{change.sf_object[:file_name]} deleted"
      else
        change.sf_object.keys.each do |key|
          commit_message += "#{key.to_s.camelize}: #{change.sf_object[key]}\n"
        end
      end

      change.apply(dir, branch.local_path)
      branch.add_changes
      branch.commit(commit_message, change.sf_object[:last_modified_by_name])

      case change.change_type
      when :deletion
        sf_objects.find_by_file_name(change.sf_object[:file_name]).delete
      when :modification
        sf_objects
        .find_by_file_name(change.sf_object[:file_name])
        .clobber(change.sf_object)
      when :addition
        sf_objects << sf_objects.new(change.sf_object)
      end

      save!
    end

    branch.push
    FileUtils.remove_entry_secure(dir)

    log.info { "Complete." }
    change_queue
  end
end
