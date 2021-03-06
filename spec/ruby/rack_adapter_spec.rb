require "spec_helper"
require "thin_proxy"

describe Faye::RackAdapter do
  include Rack::Test::Methods
  let(:adapter) { Faye::RackAdapter.new(options) }
  let(:app)     { ThinProxy.new(adapter) }
  let(:options) { {:mount => "/bayeux", :timeout => 30} }
  let(:server)  { mock "server" }
  
  after { app.stop }
  
  let(:content_type)          { last_response["Content-Type"] }
  let(:content_length)        { last_response["Content-Length"] }
  let(:cache_control)         { last_response["Cache-Control"] }
  let(:access_control_origin) { last_response["Access-Control-Allow-Origin"] }
  let(:json)                  { Yajl::Parser.parse(body) }
  let(:body)                  { last_response.body }
  let(:status)                { last_response.status.to_i }
  
  before do
    Faye::Server.should_receive(:new).with(options).and_return server
    adapter.stub(:get_client).and_return mock("client")
  end
  
  describe "POST requests" do
    describe "with cross-origin access control" do
      shared_examples_for "cross-origin request" do
        before do
          header "Origin", "http://example.com"
        end
        
        it "returns a matching cross-origin access control header" do
          server.stub(:process).and_yield []
          post "/bayeux", :message => '[]'
          access_control_origin.should == "http://example.com"
        end
        
        it "forwards the message param onto the server" do
          server.should_receive(:process).with({"channel" => "/plain"}, false).and_yield []
          post "/bayeux", "message=%7B%22channel%22%3A%22%2Fplain%22%7D"
        end
        
        it "returns the server's response as JSON" do
          server.stub(:process).and_yield ["channel" => "/meta/handshake"]
          post "/bayeux", "message=%5B%5D"
          status.should == 200
          content_type.should == "application/json"
          content_length.should == "31"
          json.should == ["channel" => "/meta/handshake"]
        end
        
        it "returns a 400 response if malformed JSON is given" do
          server.should_not_receive(:process)
          post "/bayeux", "message=%7B%5B"
          status.should == 400
          content_type.should == "text/plain"
        end
        
        it "returns a 404 if the path is not matched" do
          server.should_not_receive(:process)
          post "/blaf", 'message=%5B%5D'
          status.should == 404
          content_type.should == "text/plain"
        end
      end
      
      describe "with text/plain" do
        before { header "Content-Type", "text/plain" }
        it_should_behave_like "cross-origin request"
      end
      
      describe "with application/xml" do
        before { header "Content-Type", "application/xml" }
        it_should_behave_like "cross-origin request"
      end
    end
    
    describe "with application/json" do
      before do
        header "Content-Type", "application/json"
      end
      
      it "does not return an access control header" do
        server.stub(:process).and_yield []
        post "/bayeux", :message => '[]'
        access_control_origin.should be_nil
      end
      
      it "forwards the POST body onto the server" do
        server.should_receive(:process).with({"channel" => "/foo"}, false).and_yield []
        post "/bayeux", '{"channel":"/foo"}'
      end
      
      it "returns the server's response as JSON" do
        server.stub(:process).and_yield ["channel" => "/meta/handshake"]
        post "/bayeux", '[]'
        status.should == 200
        content_type.should == "application/json"
          content_length.should == "31"
        json.should == ["channel" => "/meta/handshake"]
      end
      
      it "returns a 400 response if malformed JSON is given" do
        server.should_not_receive(:process)
        post "/bayeux", "[}"
        status.should == 400
        content_type.should == "text/plain"
      end
      
      it "returns a 404 if the path is not matched" do
        server.should_not_receive(:process)
        post "/blaf", "[]"
        status.should == 404
        content_type.should == "text/plain"
      end
    end
    
    describe "with no content type" do
      it "forwards the message param onto the server" do
        server.should_receive(:process).with({"channel" => "/foo"}, false).and_yield []
        post "/bayeux", :message => '{"channel":"/foo"}'
      end
      
      it "returns the server's response as JSON" do
        server.stub(:process).and_yield ["channel" => "/meta/handshake"]
        post "/bayeux", :message => '[]'
        status.should == 200
        content_type.should == "application/json"
        content_length.should == "31"
        json.should == ["channel" => "/meta/handshake"]
      end
      
      it "returns a 400 response if malformed JSON is given" do
        server.should_not_receive(:process)
        post "/bayeux", :message => "[}"
        status.should == 400
        content_type.should == "text/plain"
      end
      
      it "returns a 404 if the path is not matched" do
        server.should_not_receive(:process)
        post "/blaf", :message => "[]"
        status.should == 404
        content_type.should == "text/plain"
      end
    end
  end
  
  describe "GET requests" do
    let(:params) {{:message => '{"channel":"/foo"}', :jsonp => "callback"}}
    
    describe "with valid params" do
      before do
        server.should_receive(:flush_connection).with("channel" => "/foo")
      end
      
      it "forwards the message param onto the server" do
        server.should_receive(:process).with({"channel" => "/foo"}, false).and_yield []
        get "/bayeux", params
      end
      
      it "returns the server's response as JavaScript" do
        server.stub(:process).and_yield ["channel" => "/meta/handshake"]
        get "/bayeux", params
        status.should == 200
        content_type.should == "text/javascript"
        content_length.should == "42"
        body.should == 'callback([{"channel":"/meta/handshake"}]);'
      end
      
      it "does not let the client cache the response" do
        server.stub(:process).and_yield ["channel" => "/meta/handshake"]
        get "/bayeux", params
        cache_control.should == "no-cache, no-store"
      end
    end
    
    describe "with an unknown path" do
      it "returns a 404" do
        server.should_not_receive(:process)
        get "/blah", params
        status.should == 404
        content_type.should == "text/plain"
      end
    end
    
    describe "missing jsonp" do
      before do
        params.delete(:jsonp)
        server.should_receive(:flush_connection)
      end
      
      it "returns the server's response using the default callback" do
        server.stub(:process).and_yield ["channel" => "/meta/handshake"]
        get "/bayeux", params
        status.should == 200
        content_type.should == "text/javascript"
        content_length.should == "47"
        body.should == 'jsonpcallback([{"channel":"/meta/handshake"}]);'
      end
    end
    
    shared_examples_for "bad GET request" do
      it "does not call the server" do
        server.should_not_receive(:process)
        get "/bayeux", params
      end
      
      it "returns a 400 response" do
        get "/bayeux", params
        status.should == 400
        content_type.should == "text/plain"
      end
    end
    
    describe "with malformed JSON" do
      before { params[:message] = "[}" }
      it_should_behave_like "bad GET request"
    end
    
    describe "missing message" do
      before { params.delete(:message) }
      it_should_behave_like "bad GET request"
    end
    
    describe "for the client script" do
      it "returns the client script" do
        get "/bayeux.js"
        status.should == 200
        content_type.should == "text/javascript"
        body.should =~ /function\(\)\{/
      end
    end
  end
end
