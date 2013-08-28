require 'settingslogic'
require 'yaml'
require 'pp'

## We allow for 2 configuration files. If one were to
## check their application.yml file into a publicly accessible
## repository, they could store their sensitive configuration
## or local db setttings in the application_local.yml file.
class Hash; include DeepSymbolizable; end
class Opticon::Settings < Settingslogic
	source 'application.yml'

	if File.exist? 'application_local.yml'
		instance.deep_merge!(Opticon::Settings.new('application_local.yml'))
	end
	load!
end