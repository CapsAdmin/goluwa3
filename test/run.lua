local test = require("test.gambarina")
-- Run test files
require("test.process")
require("test.threads")
require("test.buffer")
require("test.matrix")
require("test.png_decode")
-- Report test results
test:report()
