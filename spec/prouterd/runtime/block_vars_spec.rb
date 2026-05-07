require "spec_helper"

RSpec.describe "block-level vars overlay for templating" do
  let(:db) { Prouterd::Storage::DB.open(":memory:") }
  let(:runner) { Prouterd::Runner::StubRunner.new }
  let(:orchestrator) { Prouterd::Runtime::Orchestrator.new(db: db, runner: runner) }

  after { db.close }

  IFACES_VARS = <<~PRC.freeze
    interface docker img1
     image alpine:1
    exit
  PRC

  def parse(prc)
    Prouterd::Config::Parser.parse(Prouterd::Config::Lexer.tokenize(IFACES_VARS + prc))
  end

  it "exposes resolved var names at the top of the templating scope" do
    document = parse(<<~PRC)
      router demo
      exit
      process p
       block b
        interface docker img1
        command "echo {{evidence}}-{{lim}}"
        vars
         evidence "{{event.body.evidence}}"
         lim "10"
        exit
       exit
      exit
    PRC

    orchestrator.trigger(document, "p", input_event: { "body" => { "evidence" => "EVID-1" } })

    captured = runner.calls.first
    expect(captured.type_fields["command"]).to eq("echo EVID-1-10")
  end

  it "resolves each var template against the current context, not against other vars" do
    # vars are evaluated in a single pass against the base scope; chaining
    # one var's value through another is not supported (avoids surprising
    # ordering). a's value sees no `b`, b's value sees no `a` — both see
    # only the base context.
    document = parse(<<~PRC)
      router demo
      exit
      process p
       block b
        interface docker img1
        command "{{a}}|{{b}}"
        vars
         a "X"
         b "{{a}}"
        exit
       exit
      exit
    PRC

    orchestrator.trigger(document, "p", input_event: {})

    captured = runner.calls.first
    expect(captured.type_fields["command"]).to eq("X|")
  end
end
