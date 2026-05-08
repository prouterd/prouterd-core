require "spec_helper"
require "stringio"

# `kill_in_flight_containers` is invoked by run-timeout enforcement.
# A wedged docker daemon (slow socket, network-namespace tear-down,
# half-killed dockerd) can make `Docker::Container.get` block
# indefinitely — exactly the scenario the timeout is supposed to
# rescue from. The kill itself MUST be bounded.
RSpec.describe "Orchestrator#kill_in_flight_containers timeout" do
  let(:db) { Prouterd::Storage::DB.open(":memory:") }
  let(:runner) { Prouterd::Runner::StubRunner.new }
  let(:registry) { Prouterd::Runtime::InFlightRegistry.new }
  let(:io) { StringIO.new }
  let(:logger) { Prouterd::Logger.build(io, level: "debug") }
  let(:orchestrator) do
    Prouterd::Runtime::Orchestrator.new(
      db: db, runner: runner, in_flight: registry, logger: logger
    )
  end
  let(:run) do
    repo = Prouterd::Storage::Repositories::Runs.new(db)
    repo.create_run(process_name: "p", input_event: {})
  end

  after { db.close }

  before do
    # Force the docker-availability gate open without requiring docker-api.
    allow(Prouterd::Runner::DockerRunner).to receive(:docker_available?).and_return(true)
    # Stub the Docker constant to a module the spec controls. The kill
    # path only calls `Docker::Container.get`; that's the entire surface.
    stub_const("Docker", Module.new)
    container_class = Class.new do
      def self.get(_id); end
    end
    stub_const("Docker::Container", container_class)
  end

  it "abandons the kill and warns when Docker.get hangs past the cap" do
    registry.attach_container(run.uid, "ctr-stuck")
    cap = Prouterd::Runtime::Orchestrator::KILL_DOCKER_TIMEOUT_SECONDS
    # Make the docker round-trip block far longer than the cap. Test
    # passes only if the timeout actually fires.
    allow(Docker::Container).to receive(:get) { sleep(cap + 5) }

    started = Time.now
    orchestrator.send(:kill_in_flight_containers, run)
    elapsed = Time.now - started

    expect(elapsed).to be < (cap + 1)
    expect(io.string).to match(/%RUN-4-KILL_TIMEOUT: docker kill timed out.*container=ctr-stuck/)
  end

  it "is silent when Docker.get returns promptly" do
    registry.attach_container(run.uid, "ctr-fast")
    fake_container = double("Docker::Container instance")
    allow(Docker::Container).to receive(:get).and_return(fake_container)
    allow(Prouterd::Runner::DockerStop).to receive(:force_stop)

    orchestrator.send(:kill_in_flight_containers, run)
    expect(io.string).not_to include("KILL_TIMEOUT")
    expect(Prouterd::Runner::DockerStop).to have_received(:force_stop).with(fake_container)
  end
end
