require "spec_helper"

RSpec.describe Prouterd::Iface::PostgresCaller do
  let(:caller) { described_class.new }

  def build_request(dsn: "postgres://x@h/db", query:, params: nil, statement_timeout: nil)
    type_fields = { "dsn" => dsn, "query" => query }
    type_fields["params"] = params if params
    type_fields["statement-timeout"] = statement_timeout if statement_timeout

    Prouterd::Runner::RunRequest.new(
      run_uid: "run_test", process_name: "p", block_name: "b",
      execution_type: "postgres", attempt: 1,
      env: {}, input_json: {}, timeout_ms: nil,
      type_fields: type_fields, staged_inputs: {}
    )
  end

  describe "missing pg gem" do
    it "returns missing_dependency without crashing" do
      allow(described_class).to receive(:pg_available?).and_return(false)
      result = caller.run(build_request(query: "SELECT 1"))
      expect(result.error_type).to eq("missing_dependency")
      expect(result.error_message).to include("'pg' gem")
    end
  end

  describe "with pg available (stubbed)" do
    before do
      allow(described_class).to receive(:pg_available?).and_return(true)

      pg_double = Module.new
      pg_double.const_set(:Error, Class.new(StandardError))
      pg_double.const_set(:PG_DIAG_SQLSTATE, :sqlstate)
      pg_double.define_singleton_method(:connect) { |*| nil }
      stub_const("PG", pg_double)

      @conn = double("PG::Connection")
      allow(PG).to receive(:connect).and_return(@conn)
      allow(@conn).to receive(:exec).with("BEGIN")
      allow(@conn).to receive(:exec).with("COMMIT")
      allow(@conn).to receive(:exec).with("ROLLBACK")
      allow(@conn).to receive(:close)
    end

    def fake_result(rows: [], fields: [], row_count: 0)
      double("PG::Result").tap do |d|
        allow(d).to receive(:map) { |&blk| rows.map(&blk) }
        allow(d).to receive(:fields).and_return(fields)
        allow(d).to receive(:cmd_tuples).and_return(row_count)
      end
    end

    it "returns rows + row_count + fields on a successful query" do
      rows = [
        { "id" => 7, "status" => "open" },
        { "id" => 8, "status" => "closed" }
      ]
      result_set = fake_result(rows: rows, fields: %w[id status], row_count: 2)
      expect(@conn).to receive(:exec).with("SELECT id, status FROM tickets").and_return(result_set)

      result = caller.run(build_request(query: "SELECT id, status FROM tickets"))
      expect(result.exit_code).to eq(0)
      expect(result.output_json["rows"]).to eq(rows)
      expect(result.output_json["row_count"]).to eq(2)
      expect(result.output_json["fields"]).to eq(%w[id status])
    end

    it "binds params via exec_params when present" do
      empty_set = fake_result(fields: ["id"])
      expect(@conn).to receive(:exec_params)
        .with("SELECT id FROM tickets WHERE key = $1", ["JIRA-42"])
        .and_return(empty_set)

      result = caller.run(build_request(query: "SELECT id FROM tickets WHERE key = $1", params: "JIRA-42"))
      expect(result.exit_code).to eq(0)
    end

    it "splits multiple comma-separated params" do
      empty_set = fake_result
      expect(@conn).to receive(:exec_params)
        .with("INSERT ... VALUES ($1, $2, $3)", %w[a b c])
        .and_return(empty_set)

      caller.run(build_request(query: "INSERT ... VALUES ($1, $2, $3)", params: "a, b, c"))
    end

    it "respects quotes when params contain commas" do
      empty_set = fake_result
      expect(@conn).to receive(:exec_params)
        .with('INSERT ... VALUES ($1, $2)', ["Doe, John", "42"])
        .and_return(empty_set)

      caller.run(build_request(query: "INSERT ... VALUES ($1, $2)", params: '"Doe, John",42'))
    end

    it "applies statement-timeout via SET LOCAL when present" do
      result_set = fake_result
      expect(@conn).to receive(:exec).with("SET LOCAL statement_timeout = 5000").ordered
      expect(@conn).to receive(:exec).with("SELECT 1").and_return(result_set).ordered

      caller.run(build_request(query: "SELECT 1", statement_timeout: "5000"))
    end

    it "rolls back and reports sql_error on a PG::Error" do
      err = PG::Error.new("syntax error near token X")
      def err.result; nil; end

      expect(@conn).to receive(:exec).with("SELECT bogus").and_raise(err)
      expect(@conn).to receive(:exec).with("ROLLBACK")

      result = caller.run(build_request(query: "SELECT bogus"))
      expect(result.error_type).to eq("sql_error")
      expect(result.error_message).to include("syntax error")
    end

    it "categorizes SQLSTATE 57014 as a timeout" do
      result_double = double("Result")
      allow(result_double).to receive(:error_field).with(:sqlstate).and_return("57014")
      err = PG::Error.new("canceled")
      err.define_singleton_method(:result) { result_double }

      expect(@conn).to receive(:exec).with("SET LOCAL statement_timeout = 1")
      expect(@conn).to receive(:exec).with("SELECT slow").and_raise(err)
      expect(@conn).to receive(:exec).with("ROLLBACK")

      result = caller.run(build_request(query: "SELECT slow", statement_timeout: "1"))
      expect(result.error_type).to eq("timeout")
    end

    it "errors with invalid_call when query is empty" do
      result = caller.run(build_request(query: ""))
      expect(result.error_type).to eq("invalid_call")
    end

    it "errors with invalid_interface when dsn is empty" do
      result = caller.run(build_request(dsn: "", query: "SELECT 1"))
      expect(result.error_type).to eq("invalid_interface")
    end
  end
end
