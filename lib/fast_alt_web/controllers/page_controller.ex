defmodule FastAltWeb.PageController do
  use FastAltWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
