defmodule SymphonyElixir.LinearRateLimitGuardTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Linear.RateLimitGuard

  setup do
    RateLimitGuard.clear_guard_for_test()

    on_exit(fn ->
      RateLimitGuard.clear_guard_for_test()
    end)

    :ok
  end

  test "enforce_guard returns ok when no cooldown is active" do
    assert :ok == RateLimitGuard.enforce_guard()
  end

  test "normalizes explicit 429 responses and activates cooldown guard" do
    assert {429, 60_000} =
             RateLimitGuard.normalize_rate_limited_status(%{status: 429, body: %{}}, 429)

    assert {:error, {:linear_rate_limited, retry_after_ms}} = RateLimitGuard.enforce_guard()
    assert retry_after_ms > 0
    assert is_binary(RateLimitGuard.rate_limit_context(60_000))
    assert RateLimitGuard.rate_limit_context(nil) == ""
  end

  test "normalizes RATELIMITED graphql errors and clamps cooldown floor and ceiling" do
    min_duration_response = %{
      status: 400,
      body: %{
        "errors" => [
          %{
            "message" => "Rate limit exceeded",
            "extensions" => %{
              "code" => "RATELIMITED",
              "meta" => %{"rateLimitResult" => %{"duration" => 1}}
            }
          }
        ]
      }
    }

    assert {429, 5_000} = RateLimitGuard.normalize_rate_limited_status(min_duration_response, 400)
    assert {:error, {:linear_rate_limited, retry_after_ms}} = RateLimitGuard.enforce_guard()
    assert retry_after_ms > 0

    RateLimitGuard.clear_guard_for_test()

    max_duration_response = %{
      status: 400,
      body: %{
        errors: [
          %{
            message: "Rate limit exceeded",
            extensions: %{
              code: :RATELIMITED,
              meta: %{"rateLimitResult" => %{"duration" => 9_999_999}}
            }
          }
        ]
      }
    }

    assert {429, 300_000} =
             RateLimitGuard.normalize_rate_limited_status(max_duration_response, 400)
  end

  test "detects http status code metadata in 403 responses and preserves longer active guard window" do
    long_window_response = %{
      status: 400,
      body: %{
        "errors" => [
          %{
            "message" => "rate limit",
            "extensions" => %{
              "code" => "RATELIMITED",
              "meta" => %{"rateLimitResult" => %{"duration" => "120000"}}
            }
          }
        ]
      }
    }

    assert {429, 120_000} =
             RateLimitGuard.normalize_rate_limited_status(long_window_response, 400)

    shorter_window_response = %{
      status: 403,
      body: %{
        "errors" => [
          %{
            "message" => "quota",
            "extensions" => %{
              "http" => %{"status" => 429},
              "meta" => %{"rateLimitResult" => %{"duration" => 5_000}}
            }
          }
        ]
      }
    }

    assert {429, 5_000} =
             RateLimitGuard.normalize_rate_limited_status(shorter_window_response, 403)

    assert {:error, {:linear_rate_limited, retry_after_ms}} = RateLimitGuard.enforce_guard()
    assert retry_after_ms > 5_000
  end

  test "does not rewrite non rate-limited statuses" do
    non_rate_limited = %{
      status: 400,
      body: %{
        "errors" => [
          %{
            "message" => "Argument Validation Error",
            "extensions" => %{"code" => "INVALID_INPUT", "statusCode" => "400"}
          }
        ]
      }
    }

    assert {400, nil} = RateLimitGuard.normalize_rate_limited_status(non_rate_limited, 400)
    assert {500, nil} = RateLimitGuard.normalize_rate_limited_status(%{status: 500, body: "bad"}, 500)
    assert :ok == RateLimitGuard.enforce_guard()
  end

  test "handles malformed error shapes without activating a guard" do
    assert {400, nil} =
             RateLimitGuard.normalize_rate_limited_status(%{status: 400, body: %{"errors" => "oops"}}, 400)

    assert {400, nil} =
             RateLimitGuard.normalize_rate_limited_status(%{status: 400, body: :not_a_map}, 400)

    assert {400, nil} =
             RateLimitGuard.normalize_rate_limited_status(
               %{status: 400, body: %{"errors" => ["not-a-map-entry"]}},
               400
             )

    assert {400, nil} =
             RateLimitGuard.normalize_rate_limited_status(
               %{
                 status: 400,
                 body: %{
                   "errors" => [
                     %{
                       "message" => 123,
                       "extensions" => %{
                         "code" => 123,
                         "statusCode" => "invalid"
                       }
                     }
                   ]
                 }
               },
               400
             )
  end

  test "falls back to default cooldown when duration is not positive" do
    response = %{
      status: 403,
      body: %{
        "errors" => [
          %{
            "message" => 17,
            "extensions" => %{
              "code" => 17,
              "statusCode" => "429x",
              "http" => %{"status" => 429},
              "meta" => %{"rateLimitResult" => %{"duration" => "0"}}
            }
          }
        ]
      }
    }

    assert {429, 60_000} = RateLimitGuard.normalize_rate_limited_status(response, 403)
  end

  test "treats corrupted persistent guard values as inactive" do
    :persistent_term.put({RateLimitGuard, :linear_rate_limit_guard_until_ms}, "oops")
    assert :ok == RateLimitGuard.enforce_guard()
  end
end
