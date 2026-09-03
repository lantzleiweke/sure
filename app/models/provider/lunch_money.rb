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

  def initialize(access_token:)
    @access_token = access_token
    validate_configuration!
  end

  BASE_URL = "https://api.lunchmoney.dev/v2"

  def get_plaid_accounts
    get_json("/plaid_accounts")
  end

  def get_plaid_account(id)
    get_json("/plaid_accounts/#{ERB::Util.url_encode(id.to_s)}")
  end

  def get_transactions(plaid_account_id:, updated_since:, limit: 2000, offset: 0)
    value = updated_since.to_s
    rfc3339_datetime = /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:?\d{2})\z/
    raise ArgumentError, "updated_since must be an RFC3339 datetime" unless value.match?(rfc3339_datetime)

    parsed_updated_since = DateTime.iso8601(value)

    page_offset = offset
    transactions = []
    loop do
      page = get_json("/transactions", query: {
        plaid_account_id: plaid_account_id.to_s,
        updated_since: parsed_updated_since.utc.iso8601,
        include_group_children: true,
        limit: limit,
        offset: page_offset
      })
      rows = page[:transactions] || page["transactions"] || []
      raise Error.new("Empty transaction page continued pagination", :pagination_error) if rows.empty? && (page[:has_more] || page["has_more"])

      transactions.concat(rows)
      break unless page[:has_more] || page["has_more"]
      page_offset += limit
    end
    transactions
  end

  def trigger_fetch(id: nil)
    path = id ? "/plaid_accounts/fetch?plaid_account_id=#{ERB::Util.url_encode(id.to_s)}" : "/plaid_accounts/fetch"
    with_retries("POST #{path}") do
      response = request(:post, path)
      return { status: :already_fetching } if response.code.to_i == 425
      handle_response(response)
    end
  end

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

    def get_json(path, query: nil)
      with_retries("GET #{path}") do
        response = request(:get, path, query: query)
        handle_response(response)
      end
    end

    def request(method, path, query: nil)
      options = { headers: auth_headers }
      options[:query] = query if query
      self.class.public_send(method, "#{BASE_URL}#{path}", options)
    rescue *NETWORK_ERRORS => e
      raise e
    end

    NETWORK_ERRORS = Provider::HttpTransport::TRANSPORT_ERRORS

    MAX_RETRIES = 3
    INITIAL_RETRY_DELAY = 2 # seconds

    def validate_configuration!
      raise ConfigurationError, "Access token is required" if @access_token.blank?
    end

    def with_retries(operation_name, max_retries: MAX_RETRIES)
      retries = 0

      begin
        yield
      rescue JSON::ParserError, *NETWORK_ERRORS, Error => e
        retries += 1

        retryable = e.is_a?(JSON::ParserError) || !e.is_a?(Error) || e.error_type.in?([:rate_limited, :server_error])
        if retryable && retries <= max_retries
          delay = e.respond_to?(:retry_after) && e.retry_after.to_f.positive? ? e.retry_after.to_f : calculate_retry_delay(retries)
          Rails.logger.warn(
            "LunchMoney API: #{operation_name} failed (attempt #{retries}/#{max_retries}); retrying in #{delay}s"
          )
          sleep(delay)
          retry
        else
            raise e if e.is_a?(Error)
            raise Error.new("Request failed after #{max_retries} retries", :network_error)
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
      when 200, 201, 202
        body = response.body.to_s
        body.empty? ? {} : JSON.parse(body, symbolize_names: true)
      when 400
        raise Error.new("Bad request", :bad_request)
      when 401
        raise AuthenticationError.new("Invalid credentials", :unauthorized)
      when 403
        raise AuthenticationError.new("Access forbidden - check your permissions", :access_forbidden)
      when 404
        raise Error.new("Resource not found", :not_found)
      when 429
        error = Error.new("Rate limit exceeded. Please try again later.", :rate_limited)
        error.define_singleton_method(:retry_after) { Integer(response.headers["retry-after"], exception: false) || 0 }
        raise error
      when 500..599
        raise Error.new("LunchMoney server error (#{response.code}). Please try again later.", :server_error)
      else
        Rails.logger.error "LunchMoney API: Unexpected response - Code: #{response.code}"
        raise Error.new("Unexpected error: #{response.code}", :unknown)
      end
    end
end
