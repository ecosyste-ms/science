require "set"

class ProjectDeveloperAccountResolver
  WRITE_BATCH_SIZE = 1_000

  attr_reader :project, :project_contributors

  def initialize(project, project_contributors)
    @project = project
    @project_contributors = project_contributors
  end

  def resolve
    observations = project_contributors.filter_map do |contributor|
      identifiers = account_identifiers(contributor)
      next if project.host_id.blank? || identifiers.empty?

      {
        contributor: contributor,
        identifiers: identifiers,
      }
    end
    return [{}, 0, 0] if observations.empty?

    components = account_components(observations)
    existing_by_identifier = existing_accounts_by_identifier(components)
    existing_by_owner = DeveloperAccount.where(
      owner_id: components.flat_map do |component|
        component.flat_map { |observation| observation.fetch(:identifiers) }
          .filter_map { |scheme, value| value.to_i if scheme == "owner" }
      end.uniq
    ).index_by(&:owner_id)

    resolved = []
    ambiguous = 0
    components.each do |component|
      identifiers = component.flat_map { |observation| observation.fetch(:identifiers) }.uniq
      account_ids = identifiers.filter_map { |identifier| existing_by_identifier[identifier] }
      identifiers.each do |scheme, value|
        account_ids << existing_by_owner[value.to_i]&.id if scheme == "owner"
      end
      account_ids.compact!
      account_ids.uniq!
      if account_ids.length > 1
        ambiguous += component.length
        next
      end
      resolved << {
        observations: component,
        identifiers: identifiers,
        account_id: account_ids.first,
        canonical_key: account_canonical_key(identifiers),
      }
    end

    create_developer_accounts!(resolved.select { |resolution| resolution[:account_id].nil? })
    accounts_by_key = DeveloperAccount.where(
      canonical_key: resolved.pluck(:canonical_key)
    ).index_by { |account| account.canonical_key.downcase }
    resolved.each do |resolution|
      resolution[:account_id] ||= accounts_by_key[resolution.fetch(:canonical_key).downcase]&.id
    end
    create_developer_account_identifiers!(resolved)
    verified_by_identifier = existing_accounts_by_identifier(
      resolved.map { |resolution| resolution.fetch(:observations) }
    )

    assignments = {}
    resolved.each do |resolution|
      account_ids = resolution.fetch(:identifiers)
        .filter_map { |identifier| verified_by_identifier[identifier] }
        .uniq
      account_id = resolution.fetch(:account_id)
      unless account_id && account_ids == [account_id]
        ambiguous += resolution.fetch(:observations).length
        next
      end

      resolution.fetch(:observations).each do |observation|
        assignments[observation.fetch(:contributor).id] = {
          developer_account_id: account_id,
          match_kind: strongest_account_identifier(
            observation.fetch(:identifiers)
          ).first,
        }
      end
    end
    update_developer_accounts!(resolved, assignments)

    [assignments, observations.length, ambiguous]
  end

  def account_identifiers(contributor)
    identifiers = []
    identifiers << ["owner", contributor.owner_id.to_s] if contributor.owner_id
    if contributor.provider_uuid.present?
      identifiers << ["provider", contributor.provider_uuid.downcase]
    end
    identifiers << ["login", contributor.login.downcase] if contributor.login.present?
    identifiers
  end

  def account_components(observations)
    parents = observations.each_index.to_a
    identifiers = {}
    observations.each_with_index do |observation, index|
      observation.fetch(:identifiers).each do |identifier|
        if identifiers.key?(identifier)
          union_components!(parents, index, identifiers.fetch(identifier))
        else
          identifiers[identifier] = index
        end
      end
    end
    observations.each_with_index.group_by do |_, index|
      component_root(parents, index)
    end.values.map { |members| members.pluck(0) }
  end

  def component_root(parents, index)
    while parents[index] != index
      parents[index] = parents[parents[index]]
      index = parents[index]
    end
    index
  end

  def union_components!(parents, first, second)
    first_root = component_root(parents, first)
    second_root = component_root(parents, second)
    parents[second_root] = first_root unless first_root == second_root
  end

  def existing_accounts_by_identifier(components)
    identifiers = components.flatten.flat_map do |observation|
      observation.fetch(:identifiers)
    end.uniq
    return {} if identifiers.empty?

    schemes = identifiers.pluck(0).uniq
    values = identifiers.pluck(1).uniq
    allowed = identifiers.to_set
    DeveloperAccountIdentifier.where(
      host_id: project.host_id,
      scheme: schemes,
      value: values
    ).pluck(:scheme, :value, :developer_account_id).each_with_object({}) do |(scheme, value, account_id), result|
      key = [scheme, value.downcase]
      result[key] = account_id if allowed.include?(key)
    end
  end

  def account_canonical_key(identifiers)
    scheme, value = strongest_account_identifier(identifiers)
    "host:#{project.host_id}:#{scheme}:#{value}"
  end

  def strongest_account_identifier(identifiers)
    %w[owner provider login].each do |scheme|
      identifier = identifiers.find { |candidate_scheme, _| candidate_scheme == scheme }
      return identifier if identifier
    end
  end

  def create_developer_accounts!(resolutions)
    rows = resolutions.map do |resolution|
      account_attributes(resolution).merge(
        canonical_key: resolution.fetch(:canonical_key),
        host_id: project.host_id
      )
    end
    rows.each_slice(WRITE_BATCH_SIZE) do |batch|
      DeveloperAccount.insert_all(
        batch,
        unique_by: :index_developer_accounts_on_canonical_key,
        record_timestamps: true
      )
    end
  end

  def create_developer_account_identifiers!(resolutions)
    rows = resolutions.flat_map do |resolution|
      next [] unless resolution[:account_id]

      resolution.fetch(:identifiers).map do |scheme, value|
        {
          developer_account_id: resolution.fetch(:account_id),
          host_id: project.host_id,
          scheme: scheme,
          value: value,
        }
      end
    end
    rows.uniq! { |row| [row.fetch(:host_id), row.fetch(:scheme), row.fetch(:value)] }
    rows.each_slice(WRITE_BATCH_SIZE) do |batch|
      DeveloperAccountIdentifier.insert_all(
        batch,
        unique_by: :index_developer_account_identifiers_on_host_and_value,
        record_timestamps: true
      )
    end
  end

  def update_developer_accounts!(resolutions, assignments)
    accounts = DeveloperAccount.where(
      id: resolutions.filter_map { |resolution| resolution[:account_id] }
    ).index_by(&:id)
    account_rows = resolutions.filter_map do |resolution|
      account_id = resolution[:account_id]
      next unless account_id
      next unless resolution.fetch(:observations).any? do |observation|
        assignments.key?(observation.fetch(:contributor).id)
      end

      account = accounts.fetch(account_id)
      attributes = account_attributes(resolution)
      attributes.each_key do |column|
        attributes[column] = account.public_send(column) if attributes[column].blank?
      end
      attributes[:account_kind] = "bot" if account.account_kind == "bot"
      account.attributes.symbolize_keys.slice(
        :id,
        :host_id,
        :canonical_key,
        :owner_id,
        :provider_uuid,
        :login,
        :name,
        :email,
        :account_kind
      ).merge(attributes)
    end
    account_rows.each_slice(WRITE_BATCH_SIZE) do |batch|
      DeveloperAccount.upsert_all(
        batch,
        unique_by: :id,
        update_only: %i[owner_id provider_uuid login name email account_kind],
        record_timestamps: true
      )
    end
  end

  def account_attributes(resolution)
    contributors = resolution.fetch(:observations).map { |observation| observation.fetch(:contributor) }
    {
      owner_id: contributors.filter_map(&:owner_id).first,
      provider_uuid: contributors.filter_map(&:provider_uuid).first,
      login: contributors.filter_map(&:login).first,
      name: contributors.filter_map(&:name).first,
      email: contributors.filter_map(&:email).first,
      account_kind: contributors.any? { |contributor| contributor.account_kind == "bot" } ? "bot" : "unknown",
    }
  end
end
