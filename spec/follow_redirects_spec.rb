require 'helper'
require 'faraday_middleware/response/follow_redirects'
require 'faraday'

# expose a method in Test adapter that should have been public
Faraday::Adapter::Test::Stubs.class_eval { public :new_stub }

describe FaradayMiddleware::FollowRedirects do
  let(:middleware_options) { Hash.new }

  shared_examples_for 'a successful redirection' do |status_code|
    it "follows the redirection for a GET request" do
      connection do |stub|
        stub.get('/permanent') { [status_code, {'Location' => '/found'}, ''] }
        stub.get('/found') { [200, {'Content-Type' => 'text/plain'}, 'fin'] }
      end.get('/permanent').body.should eql 'fin'
    end

    [:head, :options].each do |method|
      it "returning the response headers for a #{method.to_s.upcase} request" do
        connection do |stub|
          stub.new_stub(method, '/permanent') { [status_code, {'Location' => '/found'}, ''] }
        end.run_request(method, '/permanent', nil, nil).headers['Location'].should eql('/found')
      end
    end
  end

  shared_examples_for 'a forced GET redirection' do |status_code|
    [:put, :post, :delete, :patch].each do |method|
      it "a #{method.to_s.upcase} request is converted to a GET" do
        connection = connection do |stub|
          stub.new_stub(method, '/redirect') {
            [status_code, {'Location' => '/found'}, 'elsewhere']
          }
          stub.get('/found') { |env|
            body = env[:body] and body.empty? && (body = nil)
            [200, {'Content-Type' => 'text/plain'}, body.inspect]
          }
        end.run_request(method, '/redirect', 'request data', nil).body.should eql('nil')
      end
    end
  end

  shared_examples_for 'a replayed redirection' do |status_code|
    it 'redirects with the original request headers' do
      conn = connection do |stub|
        stub.get('/redirect') {
          [status_code, {'Location' => '/found'}, '']
        }
        stub.get('/found') { |env|
          [200, {'Content-Type' => 'text/plain'}, env[:request_headers]['X-Test-Value']]
        }
      end

      response = conn.get('/redirect') { |req|
        req.headers['X-Test-Value'] = 'success'
      }

      response.body.should eql('success')
    end

    [:put, :post, :delete, :patch].each do |method|
      it "replays a #{method.to_s.upcase} request" do
        connection do |stub|
          stub.new_stub(method, '/redirect') { [status_code, {'Location' => '/found'}, ''] }
          stub.new_stub(method, '/found') { [200, {'Content-Type' => 'text/plain'}, 'fin'] }
        end.run_request(method, '/redirect', nil, nil).body.should eql 'fin'
      end
    end

    [:put, :post, :patch].each do |method|
      it "forwards request body for a #{method.to_s.upcase} request" do
        conn = connection do |stub|
          stub.new_stub(method, '/redirect') {
            [status_code, {'Location' => '/found'}, '']
          }
          stub.new_stub(method, '/found') { |env|
            [200, {'Content-Type' => 'text/plain'}, env[:body]]
          }
        end

        response = conn.run_request(method, '/redirect', 'original data', nil)
        response.body.should eql('original data')
      end
    end
  end


  it "returns non-redirect response results" do
    connection do |stub|
      stub.get('/found') { [200, {'Content-Type' => 'text/plain'}, 'fin'] }
    end.get('/found').body.should eql 'fin'
  end

  it "follows a single redirection" do
    connection do |stub|
      stub.get('/')      { [301, {'Location' => '/found'}, ''] }
      stub.get('/found') { [200, {'Content-Type' => 'text/plain'}, 'fin'] }
    end.get('/').body.should eql 'fin'
  end

  it "follows many redirections" do
    connection do |stub|
      stub.get('/')          { [301, {'Location' => '/redirect1'}, ''] }
      stub.get('/redirect1') { [301, {'Location' => '/redirect2'}, ''] }
      stub.get('/redirect2') { [301, {'Location' => '/found'}, ''] }
      stub.get('/found')     { [200, {'Content-Type' => 'text/plain'}, 'fin'] }
    end.get('/').body.should eql 'fin'
  end

  it "raises a FaradayMiddleware::RedirectLimitReached after 3 redirections (by default)" do
    conn = connection do |stub|
      stub.get('/')          { [301, {'Location' => '/redirect1'}, ''] }
      stub.get('/redirect1') { [301, {'Location' => '/redirect2'}, ''] }
      stub.get('/redirect2') { [301, {'Location' => '/redirect3'}, ''] }
      stub.get('/redirect3') { [301, {'Location' => '/found'}, ''] }
      stub.get('/found')     { [200, {'Content-Type' => 'text/plain'}, 'fin'] }
    end

    expect { conn.get('/') }.to raise_error(FaradayMiddleware::RedirectLimitReached)
  end

  it "raises a FaradayMiddleware::RedirectLimitReached after the initialized limit" do
    conn = connection(:limit => 1) do |stub|
      stub.get('/')          { [301, {'Location' => '/redirect1'}, ''] }
      stub.get('/redirect1') { [301, {'Location' => '/found'}, ''] }
      stub.get('/found')     { [200, {'Content-Type' => 'text/plain'}, 'fin'] }
    end

    expect { conn.get('/') }.to raise_error(FaradayMiddleware::RedirectLimitReached)
  end

  context 'when cookies option' do

    let(:cookies) { 'cookie1=abcdefg; cookie2=1234567; cookie3=awesome' }

    context "is :all" do
      it "puts all cookies from the response into the next request" do
        conn = connection(:cookies => :all) do |stub|
          stub.get('/')           { [301, {'Location' => '/found', 'Cookies' => cookies }, ''] }
          stub.get('/found')      { [200, {'Content-Type' => 'text/plain'}, ''] }
        end.get('/').env[:request_headers][:cookies].should == cookies
      end

      it "not set cookies header on request when response has no cookies" do
        conn = connection(:cookies => :all) do |stub|
          stub.get('/')           { [301, {'Location' => '/found'}, ''] }
          stub.get('/found')      { [200, {'Content-Type' => 'text/plain'}, ''] }
        end.get('/').env[:request_headers].has_key?('Cookies').should == false
      end
    end

    context "is an array of cookie names" do
      it "puts selected cookies from the response into the next request" do
        conn = connection(:cookies => ['cookie2']) do |stub|
          stub.get('/')           { [301, {'Location' => '/found', 'Cookies' => cookies }, ''] }
          stub.get('/found')      { [200, {'Content-Type' => 'text/plain'}, ''] }
        end.get('/').env[:request_headers][:cookies].should == 'cookie2=1234567'
      end
    end
  end

  context 'for an HTTP 301 response' do
    it_should_behave_like 'a successful redirection', 301
    it_should_behave_like 'a forced GET redirection', 301
  end

  context 'for an HTTP 302 response' do
    it_should_behave_like 'a successful redirection', 302

    context 'by default' do
      it_should_behave_like 'a forced GET redirection', 302
    end

    context 'with standards compliancy enabled' do
      let(:middleware_options) { { :standards_compliant => true } }
      it_should_behave_like 'a replayed redirection', 302
    end
  end

  context 'for an HTTP 303 response' do
    it_should_behave_like 'a successful redirection', 303
    it_should_behave_like 'a forced GET redirection', 303
  end

  context 'for an HTTP 307 response' do
    it_should_behave_like 'a successful redirection', 307
    it_should_behave_like 'a replayed redirection', 307
  end

  # checks env hash in request phase for basic validity
  class Lint < Struct.new(:app)
    def call(env)
      if env[:status] or env[:response] or env[:response_headers]
        raise "invalid request: #{env.inspect}"
      end
      app.call(env)
    end
  end

  private

  def connection(options = middleware_options)
    Faraday.new do |c|
      c.use described_class, options
      c.use Lint
      c.adapter :test do |stub|
        yield(stub) if block_given?
      end
    end
  end
end
