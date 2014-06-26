require 'git'
require 'octokit'
require 'date'

# @note Please see {SfOpticon::Scm::Base} for documentation
module SfOpticon::Scm::Github
  include SfOpticon::Scm::Base
  attr_reader :git

  ##
  # Creates a remote repository on GitHub
  #
  # The repository will 'auto_init', meaning once it's created it will
  # create its own master branch.
  #
  # @param name [String] The name of the remote repository on GitHub
  def self.create_remote_repository(name, opts = {})
    config = SfOpticon::Settings.scm.dup
    config.options.merge! opts

    # Reset this option explicitly just in case someone mucks with it
    config.options['auto_init'] = true
    SfOpticon::Logger.info { "Creating repository #{name}" }

    ##Octokit to create the repo on Github
    octo = Octokit::Client.new :login => config.username, :password => config.password

    # If the remote repository already exists we need to bomb out
    if octo.repository? Octokit::Repository.from_url "#{config.url}/#{name}"
      raise SfOpticon::Scm::RepositoryFoundException.new(
      "A repository by the name of #{name} already exists!")
    end

    # Create the remote repository, already init'd
    octo.create_repo(name, config.options)
  end

  ##
  # Instantiate the local repo objects
  def init(b_name = name)
    if Dir.exist? local_path
      log.info { "Init'ing local repository #{local_path}" }
      @git = Git.init(local_path)
      git.branch(b_name).checkout
    end
  end

  ##
  # Add the .gitignores file with package.xml
  def ignore_package_xml
    File.open(File.join(local_path, '.gitignore'), 'w') do |f|
      f.puts "package.xml"
    end
  end

  ##
  # Switches us to a branch
  def checkout(branch)
    git.checkout(branch)
  end

  ##
  # Creates a tag
  def add_tag(text)
    git.add_tag(text)
  end

  ##
  # Initializes the branch with a README.md update
  def make_branch
    log.info { "Creating branch #{name}" }
    clone
    add_changes
    commit("Branch initialization")
    push
  end

  ##
  # Executes a git pull
  def update_branch(branch_name)
    curr_branch = git.current_branch

    log.info { "Updating #{branch_name} branch with latest from remote" }

    # First we have to make sure we have the remote branch info
    checkout('master')
    git.fetch

    checkout(branch_name)
    git.pull('origin', branch_name)

    checkout(curr_branch)
    log.info { 'Complete' }
  end

  ##
  # Creates an integration branch. These will be a branch of *this*
  # branch and will be a destination for merging from some other branch.
  # It is from these branches that manifests will be generated and
  # deployed.
  #
  # @param env_name [String] The name of the environment that we'll
  #    be merging into this integration branch
  # @return [String] The name of the integration branch
  def make_integration_branch(env_name)
    # First just ensure that we're on the correct branch
    git.checkout(name)

    # Generate a name for the integration branch
    timestamp = DateTime.now.strftime("%Y%m%d%H%M%S")
    ib_name = "Integration_#{env_name}_to_#{name}_#{timestamp}"

    git.branch(ib_name).checkout
    ib_name
  end

  ##
  # Deletes an integration branch.
  #
  # @param ib_name [String] The name of the integration branch
  def delete_integration_branch(ib_name)
    log.info { "Deleting integration branch #{ib_name}"}
    checkout(name)
    git.branch(ib_name).delete
  end

  ##
  # Deletes a remote branch
  def delete_remote_branch
    log.info { "Deleting remote branch #{name}" }
    git.branch('master').checkout
    git.branch(name).delete
    git.push('origin',":#{name}")
  end

  ##
  # Performs a merge from any branch to the current branch
  #
  # @param branch [String] The branch to merge in (optional)
  # @param message [String] The merge messager (optional)
  def merge(branch = 'master', message = nil)
    log.info { "Merging branch #{branch} into #{git.current_branch}"}
    merge_result = git.merge(branch, "Merged from #{branch}")
    log.info { "Merge result: #{merge_result}" }
  end

  ##
  # Calculates the changes on a branch since its inception. This is only done
  # for integration branches, which are a throw-away and which we will be on
  # at the time. We need the other_env to look up additions in the sf_objects
  # so we have enough information for a manifest.
  #
  # @param other_env [SfOpticon::Environment] The environment we're merging in
  # @return [Hash] A hash with 2 keys, :added and :deleted, which are
  #    arrays of sf_objects
  def calculate_changes_on_int(other_env)
    changes = { :added => [], :deleted => [] }
    git.diff(name, git.current_branch).each do |commit|
      log.debug { "Adding change #{commit.type} - #{commit.path}" }

      case commit.type
      when 'modified', 'new'
        sf_object = other_env.sf_objects.find_by_file_name(commit.path)
        if sf_object
          changes[:added].push(sf_object)
        else
          log.info { "#{commit.path} isn't in the list of sf_objects." }
        end
      when 'deleted'
        sf_object = environment.sf_objects.find_by_file_name(commit.path)
        if sf_object
          changes[:deleted].push(sf_object)
        else
          log.info { "#{commit.path} doesn't exist on #{name}. Skipping deletion."}
        end
      end
    end

    changes
  end

  ##
  # Clones the repo_url into the local path and switches to the branch
  def clone
    log.info { "Cloning repository to #{local_path}"}
    @git = Git.clone(auth_url, local_path)
    git.branch(name).checkout
  end

  ##
  # Recursively adds all changes to staging
  def add_changes
    log.info { "Recursively adding all changes to staging" }
    git.add(:all => true)
  end

  ##
  # Commits all staged changes to local repository.
  #
  # @param message [String] The commit message (required)
  # @param author [String] The author of the commit (optional)
  # @param author_email [String] The author email (optional)
  def commit(message, author = nil, author_email = nil)
    log.info { "Committing all staged changes to local repository" }
    if author
      git.config('user.name', author)
    end

    if author_email
      git.config('user.email', author_email)
    end

	begin
		git.commit(message, :allow_empty => false)
	rescue
		log.info { "Ignoring empty commit" }
		# Ignore failed commits
	end
  end

  ##
  # Pushes changes to remote
  def push
    log.info { "Pushing to origin" }
    git.push('origin', "#{name}:#{name}", true)
  end
end
