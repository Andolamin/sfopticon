require 'spec_helper'

HTTPI.log = false
Savon.configure {|c| c.log = false }

describe Opticon::Schema::Environment do
	before(:each) do
		@empty_env = Opticon::Schema::Environment.new
		@prod = Opticon::Schema::Environment.first()
	end

	context "Production environment creation" do
		it "should create a production environment" do
			@prod = Opticon::Schema::Environment.create(
						:name => 'SPEC-Production',
				    	:username => Opticon::Settings.test.username,
						:password => Opticon::Settings.test.password,
						:production => true)
			@prod.id.should_not be_nil
		end

		it "should create the production scm repository and master branch"
		it "should snapshot production"
		it "should commit production metadata to scm"
	end

	context "Metaforce client" do
		it "should be able to authenticate" do
			@prod.client.send(:authenticate!).should have_key('ins0:SessionHeader')
		end

		it "should raise exception if invalid username and password" do
			@prod.username = "asdfasdf"
			@prod.password = "asdfasdf"

			expect { 
				@prod.client.send(:authenticate!)
			}.to raise_error(Savon::SOAP::Fault, /INVALID_LOGIN/)
		end

		it "should not be able to login with an empty environment" do
			expect {
				@empty_env.client.send(:authenticate!)
			}.to raise_error(Savon::SOAP::Fault, /INVALID_LOGIN/)
		end
	end

	# Tear down the production environment
	after(:all) do
		Opticon::Schema::Environment.find_by_production(true).remove()
	end
end
