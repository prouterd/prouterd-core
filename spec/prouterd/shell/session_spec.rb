require "spec_helper"

RSpec.describe Prouterd::Shell::Session do
  it "starts with an empty running config" do
    s = described_class.new
    expect(s.running_config).to be_a(Prouterd::Config::AST::Document)
  end

  it "uses default hostname when no router is set" do
    expect(described_class.new.hostname).to eq("process-router")
  end

  it "uses router hostname when configured" do
    doc = Prouterd::Config::AST::Document.new
    doc.router = Prouterd::Config::AST::Router.new(name: "x", line: 0)
    doc.router.hostname = "myrouter-1"
    s = described_class.new(running_config: doc)
    expect(s.hostname).to eq("myrouter-1")
  end

  it "replace_running swaps the in-memory document" do
    s = described_class.new
    new_doc = Prouterd::Config::AST::Document.new
    new_doc.router = Prouterd::Config::AST::Router.new(name: "fresh", line: 0)
    s.replace_running(new_doc)
    expect(s.running_config.router.name).to eq("fresh")
  end
end
