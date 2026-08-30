require "test_helper"

class PackageTest < ActiveSupport::TestCase
  setup do
    @registry = PackageRegistry.create!(
      name: "npmjs.org",
      url: "https://registry.npmjs.org",
      ecosystem: "npm",
      purl_type: "npm",
      default: true
    )
  end

  test "stores a canonical package-level purl" do
    package = Package.create!(
      package_registry: @registry,
      name: "@Fudge-AI/Browser",
      purl: "pkg:NPM/%40Fudge-AI/Browser@1.0.0#lib/index.js"
    )

    assert_equal "pkg:npm/%40Fudge-AI/Browser", package.purl
  end

  test "keeps packages with the same name separate by registry" do
    other_registry = PackageRegistry.create!(
      name: "npm.example.com",
      url: "https://npm.example.com",
      ecosystem: "npm",
      purl_type: "npm"
    )

    Package.create!(package_registry: @registry, name: "example")
    other = Package.create!(package_registry: other_registry, name: "example")

    assert_predicate other, :persisted?
  end

  test "preserves qualifiers used to distinguish a non-default registry" do
    package = Package.create!(
      package_registry: @registry,
      name: "example",
      purl: "pkg:npm/example@1.0.0?repository_url=https://npm.example.com"
    )

    assert_equal(
      "pkg:npm/example?repository_url=https://npm.example.com",
      package.purl
    )
  end

  test "checks uniqueness after purl canonicalization" do
    Package.create!(
      package_registry: @registry,
      name: "example",
      purl: "pkg:npm/example"
    )
    duplicate = Package.new(
      package_registry: @registry,
      name: "other-name",
      purl: "pkg:npm/example@1.0.0"
    )

    assert_not duplicate.valid?
    assert_includes duplicate.errors[:purl], "has already been taken"
  end

  test "requires the purl type to match the registry" do
    package = Package.new(
      package_registry: @registry,
      name: "example",
      purl: "pkg:gem/example"
    )

    assert_not package.valid?
    assert_includes package.errors[:purl], "type must match the package registry"
  end

  test "rejects an invalid purl" do
    package = Package.new(
      package_registry: @registry,
      name: "example",
      purl: "https://registry.npmjs.org/example"
    )

    assert_not package.valid?
    assert package.errors[:purl].any?
  end
end
