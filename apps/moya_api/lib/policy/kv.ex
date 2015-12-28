defmodule MoyaPolicy.Kv do
  def apply({:get, bucket, key}) do
    # Get preflist.
    # Send request to all three.
    # When request confirmed for two, return response.
    # Else timeout, return error.
  end
end
