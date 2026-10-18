# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlogWeb.AshJsonApiRouter do
  @moduledoc """
  The router the blog's JSON:API is served through, with its OpenAPI document at `/open_api`. The
  domains it routes are set by the host application's config.
  """
  use AshJsonApi.Router,
    domains: [],
    open_api: "/open_api"
end
