defmodule MoyaHashdictBackend.BucketTest do
  use ExUnit.Case, async: true

  setup do
    {:ok, bucket} = MoyaHashdictBackend.Bucket.start_link
    {:ok, bucket: bucket}
  end

  test "stores values by key", %{bucket: bucket} do
    assert MoyaHashdictBackend.Bucket.get(bucket, "funding") == nil

    MoyaHashdictBackend.Bucket.put(bucket, "funding", "cashew")
    assert MoyaHashdictBackend.Bucket.get(bucket, "funding") == "cashew"
  end

  test "deletes values by key", %{bucket: bucket} do
    MoyaHashdictBackend.Bucket.put(bucket, "funding", "cashew")

    assert MoyaHashdictBackend.Bucket.delete(bucket, "funding") == "cashew"
    assert MoyaHashdictBackend.Bucket.get(bucket, "funding") == nil
  end
end
