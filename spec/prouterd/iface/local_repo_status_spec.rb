require "spec_helper"
require "rack/test"

RSpec.describe "local_repo auto-pull status surface" do
  before { Prouterd::Iface::LocalRepoStatus.reset! }
  after  { Prouterd::Iface::LocalRepoStatus.reset! }

  describe "Iface::LocalRepoStatus" do
    it "stores the latest record per (iface, repo) pair" do
      Prouterd::Iface::LocalRepoStatus.record_pull(
        iface_name: "workspace", repo: "core", ok: true, summary: "Updated."
      )
      Prouterd::Iface::LocalRepoStatus.record_pull(
        iface_name: "workspace", repo: "core", ok: false, error: "fetch failed"
      )
      snap = Prouterd::Iface::LocalRepoStatus.snapshot
      expect(snap.length).to eq(1)
      expect(snap.first.ok).to be(false)
      expect(snap.first.error).to eq("fetch failed")
    end

    it "filters by iface_name when given" do
      Prouterd::Iface::LocalRepoStatus.record_pull(
        iface_name: "a", repo: "x", ok: true
      )
      Prouterd::Iface::LocalRepoStatus.record_pull(
        iface_name: "b", repo: "y", ok: true
      )
      expect(Prouterd::Iface::LocalRepoStatus.snapshot(iface_name: "a").length).to eq(1)
      expect(Prouterd::Iface::LocalRepoStatus.snapshot(iface_name: "a").first.repo).to eq("x")
    end
  end

  describe "GET /v1/local-repo/status" do
    include Rack::Test::Methods
    let(:db)     { Prouterd::Storage::DB.open(":memory:") }
    let(:store)  { Prouterd::ControlPlane::ConfigStore.new(db) }
    let(:runner) { Prouterd::Runner::StubRunner.new }
    let(:jobs)   { Prouterd::Storage::Repositories::Jobs.new(db) }
    let(:app) do
      Prouterd::API::App.new(
        store: store, runner: runner, jobs: jobs, admin_token: nil
      )
    end
    after { db.close }

    it "returns an array of records, one per (iface, repo) pair" do
      Prouterd::Iface::LocalRepoStatus.record_pull(
        iface_name: "workspace", repo: "core", ok: true, summary: "Already up to date."
      )
      Prouterd::Iface::LocalRepoStatus.record_pull(
        iface_name: "workspace", repo: "atp",  ok: false, error: "git pull exited 1: ..."
      )

      get "/v1/local-repo/status"
      expect(last_response.status).to eq(200)
      data = JSON.parse(last_response.body)["data"]
      expect(data.length).to eq(2)
      core = data.find { |r| r["repo"] == "core" }
      expect(core["ok"]).to be(true)
      expect(core["summary"]).to eq("Already up to date.")
      expect(core["checked_at"]).to be_a(String)
      atp = data.find { |r| r["repo"] == "atp" }
      expect(atp["ok"]).to be(false)
      expect(atp["error"]).to include("git pull exited 1")
    end

    it "returns empty data when nothing has polled yet" do
      get "/v1/local-repo/status"
      expect(JSON.parse(last_response.body)["data"]).to eq([])
    end
  end

  describe "shell `show local-repo`" do
    def drive(script, session:)
      input  = StringIO.new(script.end_with?("\n") ? script : "#{script}\n")
      out = StringIO.new
      err = StringIO.new
      Prouterd::Shell::Shell.run(
        session: session, input: input, output: out, error: err,
        interactive: false, banner: false
      )
      [out.string, err.string]
    end

    def parse(prc)
      Prouterd::Config::Parser.parse(Prouterd::Config::Lexer.tokenize(prc))
    end

    it "shows declarations and most-recent pulls per repo" do
      Prouterd::Iface::LocalRepoStatus.record_pull(
        iface_name: "workspace", repo: "core", ok: true, summary: "Already up to date."
      )
      session = Prouterd::Shell::Session.new
      session.replace_running(parse(<<~PRC))
        router demo
        exit
        interface local_repo workspace
         root /tmp/x
         whitelist core, atp
         auto-pull 5m
        exit
      PRC
      out, err = drive("enable\nshow local-repo\n", session: session)
      expect(err).to be_empty
      expect(out).to include("interface local_repo workspace")
      expect(out).to include("auto-pull: 5m")
      expect(out).to match(/core\s+ok\s+\d{4}-/)
    end

    it "says no pulls recorded when the store is empty" do
      session = Prouterd::Shell::Session.new
      session.replace_running(parse(<<~PRC))
        router demo
        exit
        interface local_repo workspace
         root /tmp/x
         whitelist a, b
         auto-pull 5m
        exit
      PRC
      out, _err = drive("enable\nshow local-repo\n", session: session)
      expect(out).to include("(no pull recorded yet)")
    end

    it "tells the operator when no local_repo interfaces exist" do
      session = Prouterd::Shell::Session.new
      session.replace_running(parse("router x\nexit\n"))
      out, _err = drive("enable\nshow local-repo\n", session: session)
      expect(out).to include("No `interface local_repo` declarations")
    end
  end
end
