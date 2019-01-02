require 'sinatra'
require 'octokit'
require 'dotenv/load'
require 'json'
require 'openssl'
require 'jwt'
require 'time'
require 'logger'

require_relative 'github_bot'

class App < Sinatra::Application
  PRIVATE_KEY = OpenSSL::PKey::RSA.new(ENV['GITHUB_PRIVATE_KEY'].gsub('\n', "\n"))
  WEBHOOK_SECRET = ENV['GITHUB_WEBHOOK_SECRET']
  APP_IDENTIFIER = ENV['GITHUB_APP_IDENTIFIER']

  configure :development do
    set :logging, Logger::DEBUG

    stack = Faraday::RackBuilder.new do |builder|
      builder.use Faraday::Request::Retry, exceptions: [Octokit::ServerError]
      builder.use Octokit::Middleware::FollowRedirects
      builder.use Octokit::Response::RaiseError
      builder.use Octokit::Response::FeedParser
      builder.response :logger
      builder.adapter Faraday.default_adapter
    end
    Octokit.middleware = stack
  end


  before '/github' do
    get_payload_request(request)
    verify_webhook_signature
    authenticate_app
    # Authenticate the app installation in order to run API operations
    authenticate_installation(@payload)
  end


  post '/github' do
    GithubBot.new(github_bot_options).on_event(request.env['HTTP_X_GITHUB_EVENT'], @payload)

    200
  end


  helpers do
    def github_bot_options
      {
        api_client: @api_client,
        installation_client: @installation_client,
        logger: logger
      }
    end

    # Saves the raw payload and converts the payload to JSON format
    def get_payload_request(request)
      # request.body is an IO or StringIO object
      # Rewind in case someone already read it
      request.body.rewind
      # The raw text of the body is required for webhook signature verification
      @payload_raw = request.body.read
      begin
        @payload = JSON.parse @payload_raw
      rescue => e
        fail  "Invalid JSON (#{e}): #{@payload_raw}"
      end
    end

    def authenticate_app
      payload = {
          # The time that this JWT was issued, _i.e._ now.
          iat: Time.now.to_i,

          # JWT expiration time (10 minute maximum)
          exp: Time.now.to_i + (10 * 60),

          # Your GitHub App's identifier number
          iss: APP_IDENTIFIER
      }

      # Cryptographically sign the JWT.
      jwt = JWT.encode(payload, PRIVATE_KEY, 'RS256')

      # Create the Octokit client, using the JWT as the auth token.
      @app_client = Octokit::Client.new(bearer_token: jwt)
    end

    # Instantiate an Octokit client, authenticated as an installation of a
    # GitHub App, to run API operations.
    def authenticate_installation(payload)
      @installation_id = payload['installation']['id']
      @installation_token = @app_client.create_app_installation_access_token(
        @installation_id, 
        accept: 'application/vnd.github.machine-man-preview+json' 
      )[:token]
      @installation_client = Octokit::Client.new(bearer_token: @installation_token)
    end

    def verify_webhook_signature
      their_signature_header = request.env['HTTP_X_HUB_SIGNATURE'] || 'sha1='
      method, their_digest = their_signature_header.split('=')
      our_digest = OpenSSL::HMAC.hexdigest(method, WEBHOOK_SECRET, @payload_raw)
      halt 401 unless their_digest == our_digest

      # The X-GITHUB-EVENT header provides the name of the event.
      # The action value indicates the which action triggered the event.
      logger.debug "---- received event #{request.env['HTTP_X_GITHUB_EVENT']}"
      logger.debug "----    action #{@payload['action']}" unless @payload['action'].nil?
    end

  end
end
