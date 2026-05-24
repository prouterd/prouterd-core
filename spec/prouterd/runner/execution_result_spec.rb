require "spec_helper"

RSpec.describe Prouterd::Runner::ExecutionResult do
  it "success? is true only when error_type is nil AND exit_code is 0" do
    success = described_class.new(error_type: nil, exit_code: 0)
    expect(success.success?).to be(true)
  end

  it "success? is false when exit_code is non-zero" do
    expect(described_class.new(error_type: nil, exit_code: 1).success?).to be(false)
  end

  it "success? is false when error_type is present" do
    expect(described_class.new(error_type: "timeout", exit_code: 0).success?).to be(false)
  end

  it "to_step_status maps success to 'success'" do
    expect(described_class.new(error_type: nil, exit_code: 0).to_step_status).to eq("success")
  end

  it "to_step_status maps timeout error_type to 'timeout'" do
    expect(described_class.new(error_type: "timeout", exit_code: nil).to_step_status).to eq("timeout")
  end

  it "to_step_status maps any other failure to 'failed'" do
    expect(described_class.new(error_type: "non_zero_exit", exit_code: 1).to_step_status).to eq("failed")
  end
end
