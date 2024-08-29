require File.expand_path('../../spec_helper', __FILE__)

module Pod
  describe Command::Compliance3 do
    describe 'CLAide' do
      it 'registers it self' do
        Command.parse(%w{ compliance3 }).should.be.instance_of Command::Compliance3
      end
    end
  end
end

