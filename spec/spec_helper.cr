require "spec"
require "webmock"
require "../src/client"
require "../src/types"

# Reset all HTTP stubs before each spec so they don't bleed across tests
Spec.before_each { WebMock.reset }
