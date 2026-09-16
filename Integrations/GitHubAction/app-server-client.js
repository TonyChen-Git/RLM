'use strict';

// GitHub downloads the complete action repository, so both adapters use the
// exact same bounded v1 client and endpoint policy without vendored drift.
module.exports = require('../VSCode/app-server-client');
