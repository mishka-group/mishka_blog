defmodule MishkaBlog.Test.PostViewGuardedStructTest do
  @moduledoc """
  GuardedStruct.AshResource coverage for `MishkaBlog.PostView`.
  """

  use MishkaBlog.DataCase, async: false
  @moduletag :unit

  if Code.ensure_loaded?(MishkaBlog) do
    alias MishkaBlog.PostView

    describe "guardedstruct wiring" do
      test "GS covers every Ash attribute" do
        assert MapSet.new([:ip_address, :user_agent, :referer]) ==
                 PostView.__guarded_field_name_set__()
      end
    end

    describe "direct __guarded_change__/1" do
      test "ip + user_agent + referer trimmed; zero-width stripped from user_agent" do
        assert {:ok,
                %{
                  ip_address: "192.168.0.1",
                  user_agent: "Mozilla/5.0",
                  referer: "https://google.com"
                }} =
                 PostView.__guarded_change__(%{
                   ip_address: "  192.168.0.1  ",
                   user_agent: "Mozil​la/5.0",
                   referer: "  https://google.com  "
                 })
      end

      test "empty ip rejected (required)" do
        assert {:error, errs} = PostView.__guarded_change__(%{ip_address: ""})
        assert Enum.any?(errs, &match?(%{field: :ip_address, action: :not_empty}, &1))
      end

      test "ip over max_len=45 → both max_len + ip fire" do
        long = String.duplicate("x", 46)

        assert {:error, errs} = PostView.__guarded_change__(%{ip_address: long})

        assert Enum.any?(errs, &match?(%{field: :ip_address, action: :max_len}, &1))
        assert Enum.any?(errs, &match?(%{field: :ip_address, action: :ip}, &1))
      end

      test "ip_address accepts IPv4 and IPv6 forms" do
        for ip <- ["127.0.0.1", "192.168.0.1", "::1", "2001:db8::1"] do
          assert {:ok, %{ip_address: ^ip}} = PostView.__guarded_change__(%{ip_address: ip})
        end
      end

      test "ip_address rejects malformed strings" do
        for bad <- ["999.999.999.999", "not-an-ip", "ten.eight.zero.one"] do
          assert {:error, errs} = PostView.__guarded_change__(%{ip_address: bad})

          assert Enum.any?(errs, &match?(%{field: :ip_address, action: :ip}, &1)),
                 "expected :ip rejection for #{inspect(bad)}, got #{inspect(errs)}"
        end
      end
    end
  end
end
