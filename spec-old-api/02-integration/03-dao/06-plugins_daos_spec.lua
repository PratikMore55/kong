local helpers = require "spec-old-api.02-integration.03-dao.helpers"
local Factory = require "kong.dao.factory"

helpers.for_each_dao(function(kong_config)
  describe("Plugins DAOs with DB: #" .. kong_config.database, function()
    it("load plugins DAOs", function()
      local factory = assert(Factory.new(kong_config))
      assert.truthy(factory.keyauth_credentials)
      assert.truthy(factory.basicauth_credentials)
      assert.truthy(factory.acls)
      assert.truthy(factory.hmacauth_credentials)
      assert.truthy(factory.jwt_secrets)
      assert.truthy(factory.oauth2_credentials)
      assert.truthy(factory.oauth2_authorization_codes)
      assert.truthy(factory.oauth2_tokens)
    end)

    describe("plugins migrations", function()
      local factory
      setup(function()
        factory = assert(Factory.new(kong_config))
      end)
      it("migrations_modules()", function()
        local migrations = factory:migrations_modules()
        assert.is_table(migrations["key-auth"])
        assert.is_table(migrations["basic-auth"])
        assert.is_table(migrations["acl"])
        assert.is_table(migrations["hmac-auth"])
        assert.is_table(migrations["jwt"])
        assert.is_table(migrations["oauth2"])
        assert.is_table(migrations["rate-limiting"])
        assert.is_table(migrations["response-ratelimiting"])
      end)
    end)
  end)
end)
