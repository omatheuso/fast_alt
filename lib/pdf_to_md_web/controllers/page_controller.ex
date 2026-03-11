defmodule PdfToMdWeb.PageController do
  use PdfToMdWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
