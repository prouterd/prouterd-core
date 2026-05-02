require "spec_helper"

# This spec doubles as the worked example for "how to add a runner type".
# A third-party developer should be able to write a single plugin file +
# a single Runner class and have parser/validator/renderer/show/tracer/
# orchestrator pick it up. This test exercises that full path on a fake
# plugin called `printer`.
RSpec.describe Prouterd::Runner::Plugin do
  # ---- The minimal third-party plugin under test ----
  let(:printer_runner_class) do
    Class.new do
      def initialize(in_flight: nil); end

      attr_reader :captured

      def run(request)
        @captured = request
        Prouterd::Runner::ExecutionResult.new(
          exit_code: 0,
          stdout: "printed: #{request.field('text')}\n",
          stderr: "",
          output_json: { "ok" => true, "text" => request.field("text") },
          artifacts: [],
          error_type: nil, error_message: nil,
          duration_ms: 1, started_at: nil, finished_at: nil
        )
      end
    end
  end

  let(:printer_plugin_class) do
    rc = printer_runner_class
    Class.new(Prouterd::Runner::Plugin) do
      type "printer"
      field :text,    kind: :string,  required: true, description: "what to print"
      field :loud,    kind: :enum, enum: %w[on off], default: "off"
      field :prefix,  kind: :string
      runner rc
    end
  end

  before do
    @saved = Prouterd::Runner::Registry.all.dup
    Prouterd::Runner::Registry.register!(printer_plugin_class)
  end

  after do
    Prouterd::Runner::Registry.clear!
    @saved.each { |p| Prouterd::Runner::Registry.register!(p) }
  end

  let(:dsl) do
    <<~PRC
      router demo
      exit
      process echo
       block say
        type printer
         text "hello world"
         loud on
         prefix "log:"
        exit
        output result
       exit
      exit
    PRC
  end

  let(:document) do
    Prouterd::Config::Parser.parse(Prouterd::Config::Lexer.tokenize(dsl))
  end

  it "parses the new type into block.type_fields without core edits" do
    block = document.processes.first.blocks.first
    expect(block.execution_type).to eq("printer")
    expect(block.type_fields).to eq(
      "text"   => "hello world",
      "loud"   => "on",
      "prefix" => "log:"
    )
  end

  it "validates required fields from the plugin schema" do
    bad = <<~PRC
      router demo
      exit
      process echo
       block say
        type printer
         loud on
        exit
       exit
      exit
    PRC
    doc = Prouterd::Config::Parser.parse(Prouterd::Config::Lexer.tokenize(bad))
    result = Prouterd::Config::Validator.validate(doc)
    expect(result.errors.map(&:message).join("\n")).to match(/\(type printer\) missing 'text'/)
  end

  it "rejects values that aren't in the plugin's enum list" do
    bad = <<~PRC
      router demo
      exit
      process echo
       block say
        type printer
         text "x"
         loud maybe
        exit
       exit
      exit
    PRC
    expect do
      Prouterd::Config::Parser.parse(Prouterd::Config::Lexer.tokenize(bad))
    end.to raise_error(Prouterd::Config::ParseError, /invalid loud 'maybe'/)
  end

  it "round-trips through the renderer (parse → render → parse) preserving fields" do
    rendered = Prouterd::Config::Renderer.render(document)
    expect(rendered).to include("type printer")
    expect(rendered).to include("text \"hello world\"")
    expect(rendered).to include("loud on")
    expect(rendered).to include("prefix log:")

    reparsed = Prouterd::Config::Parser.parse(Prouterd::Config::Lexer.tokenize(rendered))
    expect(reparsed.processes.first.blocks.first.type_fields).to eq(
      document.processes.first.blocks.first.type_fields
    )
  end

  it "renders unquoted simple words but quotes strings with whitespace" do
    src = <<~PRC
      router demo
      exit
      process echo
       block say
        type printer
         text "with spaces"
         prefix bare
        exit
       exit
      exit
    PRC
    out = Prouterd::Config::Renderer.render(
      Prouterd::Config::Parser.parse(Prouterd::Config::Lexer.tokenize(src))
    )
    expect(out).to include("text \"with spaces\"")
    expect(out).to include("prefix bare")
  end

  it "omits fields equal to their declared default from rendered output" do
    src = <<~PRC
      router demo
      exit
      process echo
       block say
        type printer
         text "with spaces"
        exit
       exit
      exit
    PRC
    doc = Prouterd::Config::Parser.parse(Prouterd::Config::Lexer.tokenize(src))
    out = Prouterd::Config::Renderer.render(doc)
    expect(out).to include("text \"with spaces\"")
    expect(out).not_to include("loud")  # default "off" is omitted
  end

  it "drives the orchestrator through the plugin's runner" do
    db = Prouterd::Storage::DB.open(":memory:")
    store = Prouterd::ControlPlane::ConfigStore.new(db)
    commit = store.commit(document)

    runners = Prouterd::Runner::Registry.all.each_with_object({}) do |plugin, h|
      h[plugin.type_name] = plugin.build_runner(in_flight: nil)
    end
    orchestrator = Prouterd::Runtime::Orchestrator.new(db: db, runner: runners)
    run = orchestrator.trigger(document, "echo", input_event: {}, commit_id: commit.id)
    expect(run.status).to eq("success")
  ensure
    db&.close
  end

  it "lists the new type in `Registry.types`" do
    expect(Prouterd::Runner::Registry.types).to include("printer")
  end

  it "auto-builds a runner of the new type via Plugin#build_runner" do
    runner = printer_plugin_class.build_runner(in_flight: nil)
    expect(runner).to be_a(printer_runner_class)
  end
end
