# frozen_string_literal: true

# Reconcile eligible IdM users into GitLab. This script is installed and run
# by the systemd unit created in developer_bootstrap.yml.

require "json"
require "securerandom"

provider = ENV.fetch("GITLAB_LDAP_PROVIDER").strip
group_path = ENV.fetch("GITLAB_DEVELOPER_GROUP_PATH").strip
user_filter = ENV.fetch("GITLAB_IDM_USER_FILTER").gsub(/\s+/, "")

adapter = Gitlab::Auth::Ldap::Adapter.new(provider)
filter = Net::LDAP::Filter.construct(user_filter)
entries = adapter.ldap_search(
  base: adapter.config.base,
  scope: Net::LDAP::SearchScope_SingleLevel,
  filter: filter,
  attributes: %w[uid cn mail dn]
)

group = Group.find_by_full_path(group_path)
raise "GitLab group #{group_path.inspect} does not exist" unless group

developer_access = Gitlab::Access::DEVELOPER
result = { created: [], updated: [], unchanged: [], errors: [] }

entries.each do |entry|
  username = Array(entry[:uid]).first.to_s.strip.downcase
  name = Array(entry[:cn]).first.to_s.strip
  email = Array(entry[:mail]).first.to_s.strip.downcase
  dn = entry.dn.to_s.strip

  begin
    raise "uid is empty" if username.empty?
    raise "cn is empty" if name.empty?
    raise "mail is empty" unless email.include?("@")
    raise "DN is empty" if dn.empty?

    identity = Identity.find_by(provider: provider, extern_uid: dn)
    by_username = User.find_by("lower(username) = ?", username)
    by_email = User.find_by("lower(email) = ?", email)
    matches = [identity&.user, by_username, by_email].compact.uniq

    if matches.length > 1
      raise "username, email, and LDAP DN resolve to different GitLab users"
    end

    user = matches.first
    created = false
    changed = false

    unless user
      password = SecureRandom.base64(48)
      user = User.new(
        username: username,
        name: name,
        email: email,
        password: password,
        password_confirmation: password,
        admin: false
      )

      if defined?(Organizations::Organization) &&
         user.respond_to?(:assign_personal_namespace)
        organization = Organizations::Organization.default_organization ||
                       Organizations::Organization.first
        user.assign_personal_namespace(organization) if organization
      end

      user.skip_confirmation!
      user.save!
      created = true
      changed = true
    end

    unless user.username.casecmp?(username)
      raise "GitLab username #{user.username.inspect} conflicts with #{username.inspect}"
    end

    unless user.email.casecmp?(email)
      raise "GitLab email #{user.email.inspect} conflicts with #{email.inspect}"
    end

    if user.name != name
      user.update!(name: name)
      changed = true
    end

    if user.respond_to?(:confirmed?) && !user.confirmed?
      user.skip_confirmation!
      user.confirm
      user.save!
      changed = true
    end

    ldap_identity = user.identities.find_by(provider: provider)
    if ldap_identity
      unless ldap_identity.extern_uid.casecmp?(dn)
        conflict = Identity.find_by(provider: provider, extern_uid: dn)
        if conflict && conflict.user_id != user.id
          raise "LDAP DN is linked to another GitLab user"
        end
        ldap_identity.update!(extern_uid: dn)
        changed = true
      end
    else
      conflict = Identity.find_by(provider: provider, extern_uid: dn)
      if conflict && conflict.user_id != user.id
        raise "LDAP DN is linked to another GitLab user"
      end
      user.identities.create!(provider: provider, extern_uid: dn)
      changed = true
    end

    membership = group.members.find_by(user_id: user.id)
    if membership.nil?
      group.add_member(user, developer_access)
      changed = true
    elsif membership.access_level < developer_access
      membership.update!(access_level: developer_access)
      changed = true
    end

    ldap_person = Gitlab::Auth::Ldap::Person.find_by_uid(username, adapter)
    raise "GitLab LDAP adapter cannot resolve user" unless ldap_person
    unless ldap_person.dn.to_s.strip.casecmp?(dn)
      raise "GitLab LDAP adapter returned a different DN"
    end

    bucket = created ? :created : (changed ? :updated : :unchanged)
    result[bucket] << username
  rescue StandardError => error
    result[:errors] << {
      username: username,
      error: "#{error.class}: #{error.message}"
    }
  end
end

puts "GITLAB_IDM_CONTINUOUS_SYNC=#{JSON.generate(result)}"
exit 1 unless result[:errors].empty?
