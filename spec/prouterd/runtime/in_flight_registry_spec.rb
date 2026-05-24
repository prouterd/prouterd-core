require "spec_helper"

RSpec.describe Prouterd::Runtime::InFlightRegistry do
  it "starts empty" do
    r = described_class.new
    expect(r.in_flight_count).to eq(0)
    expect(r.in_flight_uids).to eq([])
  end

  it "register and unregister are idempotent and counted" do
    r = described_class.new
    r.register_run("run_a")
    r.register_run("run_a") # idempotent
    r.register_run("run_b")
    expect(r.in_flight_count).to eq(2)

    r.unregister_run("run_a")
    expect(r.in_flight_count).to eq(1)
    r.unregister_run("run_x") # no-op
    expect(r.in_flight_count).to eq(1)
  end

  it "tracks attached containers per run" do
    r = described_class.new
    r.register_run("run_a")
    r.attach_container("run_a", "abc123")
    r.attach_container("run_a", "def456")
    r.attach_container("run_a", "abc123") # dedup
    expect(r.container_ids_for("run_a")).to contain_exactly("abc123", "def456")

    r.detach_container("run_a", "abc123")
    expect(r.container_ids_for("run_a")).to eq(["def456"])
  end

  it "attaches a container even before register_run (orchestrator may race)" do
    r = described_class.new
    r.attach_container("run_a", "abc")
    expect(r.container_ids_for("run_a")).to eq(["abc"])
    expect(r.in_flight_count).to eq(1)
  end

  it "in_flight? reflects presence" do
    r = described_class.new
    r.register_run("run_a")
    expect(r.in_flight?("run_a")).to be(true)
    expect(r.in_flight?("run_b")).to be(false)
  end

  it "container_ids_for returns [] for an unknown run" do
    expect(described_class.new.container_ids_for("ghost")).to eq([])
  end

  it "detach_container is a no-op when the run is unknown" do
    r = described_class.new
    expect { r.detach_container("ghost", "abc") }.not_to raise_error
  end

  it "is thread-safe under concurrent register/unregister" do
    r = described_class.new
    threads = 20.times.map do |i|
      Thread.new do
        100.times do |j|
          r.register_run("run_#{i}_#{j}")
          r.unregister_run("run_#{i}_#{j}")
        end
      end
    end
    threads.each(&:join)
    expect(r.in_flight_count).to eq(0)
  end
end
