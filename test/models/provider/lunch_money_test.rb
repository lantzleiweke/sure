require "test_helper"

class Provider::LunchMoneyTest < ActiveSupport::TestCase
  setup { @provider = Provider::LunchMoney.new(access_token: "test-token") }

  test "rejects a blank token" do
    assert_raises(Provider::LunchMoney::ConfigurationError) { Provider::LunchMoney.new(access_token: " ") }
  end

  test "gets accounts with bearer authorization" do
    Provider::LunchMoney.expects(:get).with("https://api.lunchmoney.dev/v2/plaid_accounts", has_entries(headers: has_entry("Authorization", "Bearer test-token"))).returns(response(200, { plaid_accounts: [] }.to_json))
    assert_equal({ plaid_accounts: [] }, @provider.get_plaid_accounts)
  end

  test "gets all transaction pages with the required query" do
    first = response(200, { transactions: [{ "id" => 1 }], has_more: true }.to_json)
    last = response(200, { transactions: [{ "id" => 2 }], has_more: false }.to_json)
    Provider::LunchMoney.expects(:get).with { |url, opts| url.end_with?("/transactions") && opts[:query].merge(opts[:headers]).values_at(:plaid_account_id, :updated_since, :include_group_children, :limit, :offset, "Authorization") == ["7", "2026-09-03T12:00:00Z", true, 2000, 0, "Bearer test-token"] }.returns(first)
    Provider::LunchMoney.expects(:get).with { |_, opts| opts[:query][:offset] == 2000 }.returns(last)
    result = @provider.get_transactions(plaid_account_id: 7, updated_since: "2026-09-03T12:00:00Z")
    assert_equal [ { id: 1 }, { id: 2 } ], result
  end

  test "rejects date-only updated_since and continuing empty pages" do
    assert_raises(ArgumentError) { @provider.get_transactions(plaid_account_id: 7, updated_since: "2026-09-03") }
    Provider::LunchMoney.expects(:get).returns(response(200, { transactions: [], has_more: true }.to_json))
    assert_raises(Provider::LunchMoney::Error) { @provider.get_transactions(plaid_account_id: 7, updated_since: "2026-09-03T00:00:00Z") }
  end

  test "types auth, rate limit, server and network failures" do
    [401, 403].each_with_index do |code, index|
      id = index + 1
      Provider::LunchMoney.expects(:get).with("https://api.lunchmoney.dev/v2/plaid_accounts/#{id}", anything).returns(response(code, "PRIVATE".to_json)).once
      error = assert_raises(Provider::LunchMoney::AuthenticationError) { @provider.get_plaid_account(id) }
      assert_equal(code == 401 ? :unauthorized : :access_forbidden, error.error_type)
    end
    Provider::LunchMoney.expects(:get).twice.returns(response(429, "PRIVATE".to_json, headers: { "retry-after" => "1" }), response(200, "{}".to_json))
    @provider.expects(:sleep).with(1.0)
    result = @provider.get_plaid_accounts
    assert_equal "{}", result
    Provider::LunchMoney.expects(:get).raises(Net::ReadTimeout.new("PRIVATE")).times(4)
    @provider.stubs(:sleep)
    error = assert_raises(Provider::LunchMoney::Error) { @provider.get_plaid_accounts }
    assert_equal :network_error, error.error_type
    refute_includes error.message, "PRIVATE"
  end

  test "returns fetch already running status for 425 and never exposes raw body" do
    Provider::LunchMoney.expects(:post).with("https://api.lunchmoney.dev/v2/plaid_accounts/fetch", anything).returns(response(425, "SECRET".to_json))
    result = @provider.trigger_fetch
    assert_equal :already_fetching, result[:status]
    refute_includes result.to_json, "SECRET"
  end

  test "redacts response bodies and token from terminal errors" do
    [400, 418].each do |code|
      Provider::LunchMoney.expects(:get).returns(response(code, "RAW_RESPONSE_SENTINEL"))
      error = assert_raises(Provider::LunchMoney::Error) { @provider.get_plaid_accounts }
      refute_includes error.message, "RAW_RESPONSE_SENTINEL"
    end
  end

  test "uses an unbounded server Retry-After delay" do
    Provider::LunchMoney.expects(:get).twice.returns(response(429, "RAW", headers: { "retry-after" => "61" }), response(200, "{}"))
    @provider.expects(:sleep).with(61.0)
    @provider.get_plaid_accounts
  end

  test "requires a timezone and serializes datetime as UTC" do
    Provider::LunchMoney.expects(:get).with { |_, opts| opts[:query][:updated_since] == "2026-09-03T19:00:00Z" }.returns(response(200, { transactions: [], has_more: false }.to_json))
    @provider.get_transactions(plaid_account_id: 7, updated_since: "2026-09-03T12:00:00-07:00")
    ["2026-09-03", "not-a-date", "2026-09-03T12:00:00"].each do |value|
      assert_raises(ArgumentError) { @provider.get_transactions(plaid_account_id: 7, updated_since: value) }
    end
  end

  test "retries safely retryable fetch failures but not 425 or auth failures" do
    Provider::LunchMoney.expects(:post).with("https://api.lunchmoney.dev/v2/plaid_accounts/fetch", anything).times(4).returns(*Array.new(4) { response(503, "RAW") })
    @provider.stubs(:sleep)
    error = assert_raises(Provider::LunchMoney::Error) { @provider.trigger_fetch }
    assert_equal :server_error, error.error_type
  end

  test "sanitizes malformed JSON after bounded retries" do
    Provider::LunchMoney.expects(:get).times(4).returns(*Array.new(4) { response(200, "RAW_JSON_SENTINEL") })
    @provider.stubs(:sleep)
    error = assert_raises(Provider::LunchMoney::Error) { @provider.get_plaid_accounts }
    refute_includes error.message, "RAW_JSON_SENTINEL"
    refute_includes error.message, "test-token"
  end

  test "rejects date-only, offset date-only, malformed timezone, and no-zone before HTTP" do
    Provider::LunchMoney.expects(:get).never
    ["2026-09-03", "2026-09-03+07:00", "2026-09-03T12:00:00+bad", "2026-09-03T12:00:00"].each do |value|
      assert_raises(ArgumentError) { @provider.get_transactions(plaid_account_id: 7, updated_since: value) }
    end
  end

  test "fetch retries 429 using Retry-After above 30 seconds" do
    Provider::LunchMoney.expects(:post).twice.returns(response(429, "RAW", headers: { "retry-after" => "61" }), response(202, ""))
    @provider.expects(:sleep).with(61)
    @provider.trigger_fetch
  end

  test "fetch retries shared transport errors and does not retry 425 or auth" do
    Provider::LunchMoney.expects(:post).times(4).raises(Provider::HttpTransport::TRANSPORT_ERRORS.first.new("RAW"))
    @provider.stubs(:sleep)
    assert_raises(Provider::LunchMoney::Error) { @provider.trigger_fetch }

    [425, 401, 403].each do |code|
      Provider::LunchMoney.expects(:post).once.returns(response(code, "RAW"))
      @provider.expects(:sleep).never
      if code == 425
        assert_equal :already_fetching, @provider.trigger_fetch[:status]
      else
        assert_raises(Provider::LunchMoney::AuthenticationError) { @provider.trigger_fetch }
      end
    end
  end

  private

    def response(code, body, headers: {})
      OpenStruct.new(code: code, body: body, message: "message", headers: headers)
    end
end
