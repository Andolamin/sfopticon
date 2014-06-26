class SfOpticon::Changes::Diff
  ##
  # Generates a basic changeset between to snapshots of the same environment.
  #
  # @param orig_snap 
  # @param new_snap
  # @return Array A list of the changes between snapshots
  def self.snap_diff(orig_snap, new_snap)
    log = SfOpticon::Logger
    changes = SfOpticon::Changes::Queue.new

    # Make a simple sf name search array to check for adds and deletes
	orig_snap_hash, new_snap_hash = Hash.new, Hash.new
    orig_snap.each do |o|
	  orig_snap_hash[o[:file_name]] = o
	  puts o
    end
    new_snap.each do |o|
	  new_snap_hash[o[:file_name]] = o
	  puts o
    end

    # And perform the deletion check
    (orig_snap_hash.keys - new_snap_hash.keys).each do |key|
      log.info { "Deletion detected: #{orig_snap_hash[key][:full_name]}"}
      changes.deletions << SfOpticon::Changes::Deletion.new(orig_snap_hash[key])
    end

    # Now perform the addition check
    (new_snap_hash.keys - orig_snap_hash.keys).each do |key|
      log.info { "Addition detected: #{new_snap_hash[key][:full_name]}" }
      changes.additions << SfOpticon::Changes::Addition.new(new_snap_hash[key])
    end

    # Now mods
    (orig_snap_hash.keys & new_snap_hash.keys).each do |key|
	  # Type
	  o_type = orig_snap_hash[key][:object_type]
	  n_type = new_snap_hash[key][:object_type]
	
      # Last mod times
      o_last_m = orig_snap_hash[key][:last_modified_date]
      n_last_m = new_snap_hash[key][:last_modified_date]

      # Full names and file names to catch renames
      o_full_name = orig_snap_hash[key][:full_name]
      n_full_name = new_snap_hash[key][:full_name]
      o_file_name = orig_snap_hash[key][:file_name]
      n_file_name = new_snap_hash[key][:file_name]

      # puts new_snap_hash[key];
	  
	  force_change = SfOpticon::Settings.salesforce.force_change.include? o_type
	  
      if o_last_m != n_last_m or force_change
        log.info { "Modification detected: #{orig_snap_hash[key][:full_name]}" }
        changes.modifications << SfOpticon::Changes::Modification.new(new_snap_hash[key])
      end
    end

    changes
  end
end
