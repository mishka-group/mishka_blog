# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlogWeb.AshJsonApiRouter do
  use AshJsonApi.Router,
    domains: [],
    open_api: "/open_api"
end
