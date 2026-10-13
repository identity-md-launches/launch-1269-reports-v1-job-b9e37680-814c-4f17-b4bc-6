import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {oracleQuestionHash} from '../tools/oracle_question_hash.mjs';
import {bytesCall,storedAnswer} from '../keeper/lib/oracle.mjs';
import {swarmConstructorArgs} from '../tools/swarm_constructor_args.mjs';
import {keccak256,utf8,word,decodeWords} from '../keeper/lib/eth.mjs';
const vectors=JSON.parse(readFileSync('test/fixtures/oracle-hash-vectors.json','utf8')).vectors;
for(const v of vectors)assert.equal(oracleQuestionHash(v.body),v.questionHash);
const config=JSON.parse(readFileSync('docs/oracle-v37/oracle-config.json','utf8'));
// Local encoder fixtures only: never a production launch configuration.
const binding={factory:'0x9c9d2fcb75c2c132c0ac0c42df3819a42347265e',registryLaunch:'0',registryIndex:0,paramsLaunch:'0',paramsIndex:0,heartbeatBps:200,heartbeatCap:'1000000000000000000',gameConfigHash:keccak256(utf8('fixture'))};
const constructorArgs=swarmConstructorArgs(config,binding);
assert.equal(constructorArgs.length,7);assert.equal(constructorArgs.map(word).join('').length,7*64);
assert.throws(()=>swarmConstructorArgs({...config,intake:'0x'+'11'.repeat(20)},binding),/constant/);
assert.throws(()=>swarmConstructorArgs(config,{...binding,factory:'0x'+'11'.repeat(20)}),/constant/);
// v3.9 policy word: chainId[0:32] | fromBlock[32:80] | toBlock[80:128] | maxPrice[128:224] | heartbeatBps[224:240].
const policy=BigInt(constructorArgs[1]),m32=(1n<<32n)-1n,m48=(1n<<48n)-1n,m96=(1n<<96n)-1n;
assert.equal(policy&m32,1n);assert.equal((policy>>32n)&m48,26122900n);assert.equal((policy>>80n)&m48,26122901n);
assert.equal((policy>>128n)&m96,500000000000000000n);assert.equal(policy>>224n,200n);
assert.throws(()=>swarmConstructorArgs(config,{...binding,registryIndex:1}));
assert.throws(()=>swarmConstructorArgs(config,{...binding,registryLaunch:'812'}));
assert.throws(()=>swarmConstructorArgs(config,{...binding,heartbeatCap:'2'}));
assert.throws(()=>swarmConstructorArgs(config,{...binding,heartbeatBps:199}));
assert.throws(()=>swarmConstructorArgs({...config,questionChain:1n<<32n},binding));
assert.throws(()=>swarmConstructorArgs({...config,maxPrice:'0'},binding));
for(const [i,name]of ['event','regulator'].entries()) {
 const text=readFileSync(`docs/oracle-v37/${name}.json`,'utf8');const body=JSON.parse(text);
 assert.equal(oracleQuestionHash(body),config.questions[i]);assert.equal(keccak256(utf8(text)),config.bodies[i]);
 assert.equal(body.head,i===0?7:17);assert.ok(Buffer.byteLength(text)<16384);
 for(const [key,value]of Object.entries(body.definitions)){assert.ok(key.length<=64);assert.ok(value.length<=512);}
 assert.notEqual(oracleQuestionHash({...body,head:1}),config.questions[i]);
 assert.notEqual(oracleQuestionHash({...body,definitions:{...body.definitions,policy:'attacker'}}),config.questions[i]);
 assert.equal(oracleQuestionHash({...body,deliver:{chainId:4663,target:'routing excluded'}}),config.questions[i]);
 const answer='0x'+word(32)+word(body.head)+Array.from({length:body.head},(_,j)=>word(j)).join('');
 const encoded=bytesCall('execute(uint8,bytes)',i,answer);
 const args=decodeWords('0x'+encoded.slice(10));assert.equal(args[0],BigInt(i));assert.equal(args[1],64n);assert.equal(args[2],BigInt((answer.length-2)/2));
 const log={topics:['unused','0x'+word(i),'0x'+word(9)],data:'0x'+word(12)+word(64)+word((answer.length-2)/2)+answer.slice(2)};
 assert.deepEqual(storedAnswer(log),{stream:i,id:'0x'+word(9),answer});
 assert.equal(storedAnswer({...log,removed:true}),null);
}
assert.throws(()=>bytesCall('execute(uint8,bytes)',0,'0xzz'));
assert.throws(()=>oracleQuestionHash({...vectors[0].body,window:{hours:6}}));
console.log(`${vectors.length} independent protocol hash vectors; commitments, twelve-word constructor packing, field limits, dynamic keeper ABI and log recovery passed.`);
