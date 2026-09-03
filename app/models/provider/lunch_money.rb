# frozen_string_literal: true

class Provider::LunchMoney
  include HTTParty

  headers "User-Agent" => "Sure Finance LunchMoney Client"
  default_options.merge!(verify: true, ssl_verify_mode: OpenSSL::SSL::VERIFY_PEER, timeout: 120)

  class Error < StandardError
    attr_reader :error_type

    def initialize(message, error_type = :unknown)
      super(message)
      @error_type = error_type
    end
  end

  class ConfigurationError < Error; end
  class AuthenticationError < Error; end

  attr_reader :access_token

  def initialize(access_token:)
    @access_token = access_token
    validate_configuration!
  end

  # TODO: Implement provider-specific API methods
  # Example methods for banking providers:

  # def list_accounts
  #   with_retries("list_accounts") do
  #     response = self.class.get(
  #       "#{base_url}/accounts",
  #       headers: auth_headers
  #     )
  #     handle_response(response)
  #   end
  # end

  # def get_transactions(account_id:, start_date:, end_date: Date.current, include_pending: true)
  #   with_retries("get_transactions") do
  #     response = self.class.get(
  #       "#{base_url}/accounts/#{account_id}/transactions",
  #       headers: auth_headers,
  #       query: {
  #         start_date: start_date.to_s,
  #         end_date: end_date.to_s,
  #         include_pending: include_pending
  #       }
  #     )
  #     handle_response(response)
  #   end
  # end

  # def get_balance(account_id:)
  #   with_retries("get_balance") do
  #     response = self.class.get(
  #       "#{base_url}/accounts/#{account_id}/balance",
  #       headers: auth_headers
  #     )
  #     handle_response(response)
  #   end
  # end

  private

    RETRYABLE_ERRORS = [
      SocketError, Net::OpenTimeout, Net::ReadTimeout,
      Errno::ECONNRESET, Errno::ECONNREFUSED, Errno::ETIMEDOUT, EOFError
    ].freeze

    MAX_RETRIES = 3
    INITIAL_RETRY_DELAY = 2 # seconds

    def validate_configuration!
      raise ConfigurationError, "Access token is required" if @access_token.blank?
    end

    def with_retries(operation_name, max_retries: MAX_RETRIES)
      retries = 0

      begin
        yield
      rescue *RETRYABLE_ERRORS => e
        retries += 1

        if retries <= max_retries
          delay = calculate_retry_delay(retries)
          Rails.logger.warn(
            "LunchMoney API: #{operation_name} failed (attempt #{retries}/#{max_retries}): " \
            "#{e.class}: #{e.message}. Retrying in #{delay}s..."
          )
          sleep(delay)
          retry
        else
          Rails.logger.error(
            "LunchMoney API: #{operation_name} failed after #{max_retries} retries: " \
            "#{e.class}: #{e.message}"
          )
          raise Error.new("Network error after #{max_retries} retries: #{e.message}", :network_error)
        end
      end
    end

    def calculate_retry_delay(retry_count)
      base_delay = INITIAL_RETRY_DELAY * (2 ** (retry_count - 1))
      jitter = base_delay * rand * 0.25
      [ base_delay + jitter, 30 ].min
    end

    def auth_headers
      # TODO: Customize based on your provider's authentication method
      {
        "Authorization" => "Bearer #{@access_token}",
        "Content-Type" => "application/json",
        "Accept" => "application/json"
      }
    end

    def handle_response(response)
      case response.code
      when 200, 201
        JSON.parse(response.body, symbolize_names: true)
      when 400
        Rails.logger.error "LunchMoney API: Bad request - #{response.body}"
        raise Error.new("Bad request: #{response.body}", :bad_request)
      when 401
        raise AuthenticationError.new("Invalid credentials", :unauthorized)
      when 403
        raise AuthenticationError.new("Access forbidden - check your permissions", :access_forbidden)
      when 404
        raise Error.new("Resource not found", :not_found)
      when 429
        raise Error.new("Rate limit exceeded. Please try again later.", :rate_limited)
      when 500..599
        raise Error.new("LunchMoney server error (#{response.code}). Please try again later.", :server_error)
      else
        Rails.logger.error "LunchMoney API: Unexpected response - Code: #{response.code}, Body: #{response.body}"
        raise Error.new("Unexpected error: #{response.code} - #{response.body}", :unknown)
      end
    end
end
