defmodule MishkaBlog.ConnCase do
  @moduledoc """
  Test case for the extension's JSON API, standing in for the CMS's `MishkaCmsWeb.ConnCase`.

  Same contract as the CMS's — a sandboxed connection per test and a `conn` to drive it with — but
  pointed at this extension's own `MishkaBlog.TestEndpoint`, so the suite runs without the CMS around
  it. See the test-only `MishkaBlog.Repo` shim for how the database is reached.

  `make_api_request/3` is here rather than in the factory: it builds requests, it does not build data.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      @endpoint MishkaBlog.TestEndpoint

      import Plug.Conn
      import Phoenix.ConnTest
      import MishkaBlog.ConnCase
    end
  end

  setup tags do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(MishkaBlog.Repo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)

    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  @doc """
  Calls the JSON:API the way a client does, and returns the `Plug.Conn` it answered with.

  The conn is built by hand rather than through `Phoenix.ConnTest.post/3`, and its query string is
  decoded the way Phoenix decodes a real request: JSON:API puts structure in it —
  `page[limit]=2`, `included_page[posts][limit]=1`, `filter[author][email][contains]=x` — and each
  bracket is one level of the nested map the router receives, however deep.

  `host` matters: the tenant plug resolves which site a request belongs to from it, so a test that
  changes hosts is testing a different tenant.

  ## Options
    * `:method`  — defaults to `"POST"`
    * `:host`    — defaults to `"localhost"`
    * `:headers` — extra request headers, e.g. the bearer token from signing in
  """
  @spec make_api_request(String.t(), term(), keyword()) :: Plug.Conn.t()
  def make_api_request(path, data, opts \\ []) do
    headers = Keyword.get(opts, :headers, [])
    host = Keyword.get(opts, :host, "localhost")
    method = Keyword.get(opts, :method, "POST")

    {base_path, query_string} =
      case String.split(path, "?", parts: 2) do
        [p, q] -> {p, q}
        [p] -> {p, ""}
      end

    query_params = Plug.Conn.Query.decode(query_string)

    %Plug.Conn{} = conn = Phoenix.ConnTest.build_conn()

    %{
      conn
      | host: host,
        method: String.upcase("#{method}"),
        request_path: path,
        path_info: base_path |> String.trim_leading("/") |> String.split("/"),
        query_string: query_string,
        query_params: query_params,
        params: query_params
    }
    |> put_default_headers()
    |> put_custom_headers(headers)
    |> Map.put(:body_params, %{"data" => data})
    |> Map.update!(:params, &Map.merge(&1, %{"data" => data}))
    |> MishkaBlog.TestEndpoint.call([])
  end

  @doc """
  The resources of `type` a JSON:API response carried in `included`. A refused include answers with
  an error document, which has no `included` at all, so that reads as none.
  """
  @spec included(Plug.Conn.t(), String.t()) :: [map()]
  def included(%Plug.Conn{} = response, type) do
    response.resp_body
    |> Jason.decode!()
    |> Map.get("included")
    |> List.wrap()
    |> Enum.filter(&(&1["type"] == type))
  end

  @doc """
  What a rendered `user` resource says about the account behind it: its own fields, and the site and
  the permissions it holds. A withheld field is left out, and a withheld site or permission list
  comes back empty, which says nothing, so only the ones carrying something are returned.
  """
  @spec account_fields(map()) :: map()
  def account_fields(user) do
    (user["attributes"] || %{})
    |> Map.take(["email", "confirmed_at", "permission_values", "site_id", "site", "permissions"])
    |> Map.reject(fn {_field, value} -> value in [nil, []] end)
  end

  defp put_default_headers(conn) do
    conn
    |> Plug.Conn.put_req_header("content-type", "application/vnd.api+json")
    |> Plug.Conn.put_req_header("accept", "application/vnd.api+json")
  end

  defp put_custom_headers(conn, headers) do
    Enum.reduce(headers, conn, fn {key, value}, acc ->
      Plug.Conn.put_req_header(acc, key, value)
    end)
  end
end
