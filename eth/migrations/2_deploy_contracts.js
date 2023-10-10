const fs = require('node:fs');
const Membrane = artifacts.require("Membrane");
const TruffleConfig = require('../truffle-config.js');

module.exports = async function (deployer, network, accounts) {
        const options = {gas: 1e6, from: accounts[0]};
        await deployer.deploy(Membrane, [accounts[0]], 1, options);
        const instance = await Membrane.deployed();

        const addresses = {
                membrane: instance.address,
        };
        fs.writeFileSync('addresses.json', JSON.stringify(addresses));
};
