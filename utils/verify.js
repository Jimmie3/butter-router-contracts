async function sleep(delay) {
    return new Promise((resolve) => setTimeout(resolve, delay));
}

exports.verify = async function (addr, args, code, chainId, wait) {
    console.log(args);
    const verifyArgs = args.map((arg) => (typeof arg == "string" ? `'${arg}'` : arg)).join(" ");
    console.log(`To verify, run: \n npx hardhat verify --network <Network> --contract ${code} ${addr} ${verifyArgs}`);

    if (needVerify(chainId)) {
        if (wait) {
            await sleep(20000);
        }
        console.log(`verify ${code} ...`);
        console.log("addr:", addr);
        console.log("args:", args);

        await run("verify:verify", {
            contract: code,
            address: addr,
            constructorArguments: args,
        });
    }
};

function needVerify(chainId) {
    let needs = [
        1, // eth
        56, // bsc
        137, // matic
        199, // bttc
        81457, // blast
        8453, // base
        324, // zksync
        10, //op
        42161, // arb
        59144, // linea
        534352, // scoll
        5000, // mantle
        11155111, // sepolia
        // 97, // bsctest
        421614, // arbitrum sepolia
    ];
    if (needs.includes(chainId)) {
        return true;
    } else {
        return false;
    }
}

function needSourcify(chainId) {
    let needs = [
        //22776, // mapo
    ];
    if (needs.includes(chainId)) {
        return true;
    } else {
        return false;
    }
}
