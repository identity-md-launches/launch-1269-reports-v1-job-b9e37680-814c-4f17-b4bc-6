#!/usr/bin/env node
// Offline packing for the launcher's seven-word SwarmDesk constructor (v3.14). No RPC or signing.
// The intake, delivery, signer, asset and factory are bytecode constants (src/lib/IMD.sol): the config file
// must still name them, and they must equal the constants, but they are never constructor words (deploy gate).
// policyWord = chainId[0:32] | fromBlock[32:80] | toBlock[80:128] | maxPrice[128:224] | heartbeatBps[224:240].
import {readFileSync} from 'node:fs';
import {pathToFileURL} from 'node:url';

function uint(value,bits,name,min=0n) {
  if(typeof value==='number'&&!Number.isSafeInteger(value))throw Error(`Use a decimal string for ${name}`);
  let n;try{n=BigInt(value);}catch{throw Error(`Invalid ${name}`);}
  if(n<min||n>=(1n<<BigInt(bits)))throw Error(`Out of range ${name}`);
  return n;
}
function address(value,name) {
  if(!/^0x[0-9a-fA-F]{40}$/.test(value)||BigInt(value)===0n)throw Error(`Invalid ${name}`);
  return value;
}
function hash(value,name) {
  if(!/^0x[0-9a-fA-F]{64}$/.test(value)||BigInt(value)===0n)throw Error(`Invalid ${name}`);
  return value;
}
export function policyWord(o,b) {
  const chain=uint(o.questionChain,32,'questionChain',1n),from=uint(o.fromBlock,48,'fromBlock'),to=uint(o.toBlock,48,'toBlock');
  if(to<from)throw Error('Reversed context window');
  const price=uint(o.maxPrice,96,'maxPrice',1n);
  const rl=uint(b.registryLaunch??0,64,'registryLaunch'),ri=uint(b.registryIndex??0,3,'registryIndex');
  const pl=uint(b.paramsLaunch??0,64,'paramsLaunch'),pi=uint(b.paramsIndex??0,3,'paramsIndex');
  if(rl!==0n||ri!==0n||pl!==0n||pi!==0n)throw Error('Launch coordinates are proven at bind time, not in the constructor');
  const bps=uint(b.heartbeatBps,16,'heartbeatBps');
  if(bps<200n||bps>5000n||BigInt(b.heartbeatCap)!==10n**18n)throw Error('Invalid heartbeat configuration');
  return chain|(from<<32n)|(to<<80n)|(price<<128n)|(bps<<224n);
}
export const IMD_CONSTANTS={intake:'0xa43e6f75ee006411f79ac1c84120606c2330de82',delivery:'0xce0e6a670aa75e161d02aca3c7f00b94ca428ccb',
  signer:'0x5598aa9146215bc13eb26f2c692ad1461fd32982',asset:'0x5f7bb59365ce557c26dbcaa4ee9d39a4b95b7127',factory:'0x9c9d2fcb75c2c132c0ac0c42df3819a42347265e'};
export function swarmConstructorArgs(o,b) {
  for(const k of ['intake','delivery','signer','asset'])if(address(o[k],k).toLowerCase()!==IMD_CONSTANTS[k])throw Error(`${k} must equal the bytecode constant ${IMD_CONSTANTS[k]}`);
  if(address(b.factory,'factory').toLowerCase()!==IMD_CONSTANTS.factory)throw Error(`factory must equal the bytecode constant ${IMD_CONSTANTS.factory}`);
  if(o.questions[0].toLowerCase()===o.questions[1].toLowerCase())throw Error('Duplicate question commitments');
  return [hash(o.action,'action'),policyWord(o,b).toString(),
    hash(o.questions[0],'eventQuestion'),hash(o.questions[1],'regulatorQuestion'),hash(o.bodies[0],'eventBody'),hash(o.bodies[1],'regulatorBody'),
    hash(b.gameConfigHash,'gameConfigHash')];
}
if(process.argv[1]&&import.meta.url===pathToFileURL(process.argv[1]).href) {
  if(process.argv.length!==4)throw Error('Usage: node tools/swarm_constructor_args.mjs oracle-config.json approved-binding.json');
  const [o,b]=process.argv.slice(2).map(p=>JSON.parse(readFileSync(p,'utf8')));
  console.log(JSON.stringify({constructorArgs:swarmConstructorArgs(o,b)},null,2));
}
