const { SafeFactory } = require('@gnosis.pm/safe-core-sdk');
const { network, ethers } = require("hardhat");
const { EthersAdapter } = require('@safe-global/protocol-kit');
// const { HardhatProvider } = require('@nomicfoundation/hardhat-ethers');

async function main() {

    switch (network.name) {
    case 'development':
        const provider = await ethers.provider;
        const safeOwner = await provider.getSigner(0)
        const ethAdapter = new EthersAdapter({
            ethers,
            signerOrProvider: safeOwner
        })

        // deploy gnosis contracts
        const GnosisSafeProxyFactory = await ethers.getContractFactory("GnosisSafeProxyFactory");
        console.log("Deploying GnosisSafeProxyFactory...");
        const gnosisSafeProxyFactory = await GnosisSafeProxyFactory.deploy();
        console.log("GnosisSafeProxyFactory deployed to:", gnosisSafeProxyFactory.target);

        const GnosisSafe = await ethers.getContractFactory("GnosisSafe");
        console.log("Deploying GnosisSafe...");
        const gnosisSafe = await GnosisSafe.deploy();
        console.log("GnosisSafe deployed to:", gnosisSafe.target);

        const MultiSend = await ethers.getContractFactory("MultiSend");
        console.log("Deploying MultiSend...");
        const multiSend = await MultiSend.deploy();
        console.log("MultiSend deployed to:", multiSend.target);

        const chainId = await ethAdapter.getChainId()

        const contractNetworks = {
            [chainId]: {

                multiSendAddress: multiSend.target,
                // multiSendAbi: multiSendAbi,

                safeMasterCopyAddress: gnosisSafe.target,
                // safeMasterCopyAbi: safeAbi,

                safeProxyFactoryAddress: gnosisSafeProxyFactory.target,
                // safeProxyFactoryAbi: proxyFactoryAbi,

            }
        }

        console.log("@@@ contractNetworks", contractNetworks);
       
        const safeFactory = await SafeFactory.create({ ethAdapter, contractNetworks });


        break;
        // TODO: for other networks augment hardhat config with the addresses of the already deployed gnosis contracts
    default:
        console.log(`Unknown network ${network.name}`);
        process.exit(-1);
    }

}


main().catch((error) => {
    console.error(error);
    process.exitCode = 1;
});
