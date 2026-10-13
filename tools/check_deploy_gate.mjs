#!/usr/bin/env node
// BLACKOUT v3.14 deploy-gate check. The IMD manifest gate refuses any constructor argument equal to an IMD
// protocol address (deploy-gate refusal of launch 1557). Every launch's constructor words are listed here
// exactly as they appear in launch-v39.md (L1-L4); the check fails if any word equals one of the addresses.
// Platform placeholders ($poolManager, $token, $factory, $contract:Name) and requester values (<...>) are allowed.
// Usage: node tools/check_deploy_gate.mjs            (exit 1 on any hit)
import {readFileSync} from 'node:fs';

export const IMD_ADDRESSES = {
  ProjectFactory: '0x9c9d2fcb75c2c132c0ac0c42df3819a42347265e',
  ProjectRecords: '0xf52bbe066b7ad2d28c2195d066ea08dcbca88406',
  Intake: '0xa43e6f75ee006411f79ac1c84120606c2330de82',
  IntakeDelivery: '0xce0e6a670aa75e161d02aca3c7f00b94ca428ccb',
  Attester: '0x5598aa9146215bc13eb26f2c692ad1461fd32982',
  RobinhoodIMD: '0x5f7bb59365ce557c26dbcaa4ee9d39a4b95b7127',
  LaunchFactory: '0xa25b02a1e93903b790e6aaf7da1b8b8d50294645',
  PoolManager: '0x8366a39cc670b4001a1121b8f6a443a643e40951',
};

/** The four launches and the constructor words of every contract, as pasted into the objectives. */
export const LAUNCHES = {
  L1: {
    SwarmDesk: ['<ACTION>', '<POLICY_WORD>', '<EVENT_QUESTION>', '<REGULATOR_QUESTION>', '<EVENT_BODY>', '<REGULATOR_BODY>', '<GAME_CONFIG_HASH>'],
    EndowmentEscrow: ['$contract:SwarmDesk'],
  },
  L2: {
    V4Market: ['$poolManager', '$token', '12500', '60', '$factory', '<DESK>', '<GAME_CONFIG_HASH>'],
  },
  L3: {
    Params: ['<DESK>', '200', '1000000000000000000'],
    GameRegistry: ['<TOKEN>', '$contract:Params', '<HOOK>', '<STARTER_ROOT>', '<FREE_ROOT>', '<SNAPSHOT_BLOCK>', '200000000000000000000000000'],
    RewardPool: ['$contract:GameRegistry'], FarmRewards: ['$contract:GameRegistry'], FarmCore: ['$contract:GameRegistry'],
    FarmItems: ['$contract:GameRegistry'], PackSale: ['$contract:GameRegistry'], StarterClaim: ['$contract:GameRegistry'],
  },
  L4: {
    FeeRouter: ['<REGISTRY>'], GridOperator: ['<REGISTRY>'], Season: ['<REGISTRY>'], FarmEngine: ['<REGISTRY>'],
    Economy: ['<REGISTRY>'], Enhancement: ['<REGISTRY>'], Civic: ['<REGISTRY>'], Billboards: ['<REGISTRY>'],
  },
};

export function checkWords(launches, addresses = IMD_ADDRESSES) {
  const hits = [];
  const banned = new Map(Object.entries(addresses).map(([name, a]) => [a.toLowerCase(), name]));
  for (const [launch, contracts] of Object.entries(launches)) {
    for (const [contract, words] of Object.entries(contracts)) {
      words.forEach((w, i) => {
        const word = String(w).trim().toLowerCase();
        if (banned.has(word)) hits.push({launch, contract, index: i, word, address: banned.get(word)});
        // A 32-byte word left-padded from an address is the same address to the gate.
        if (/^0x[0-9a-f]{64}$/.test(word) && banned.has('0x' + word.slice(26))) hits.push({launch, contract, index: i, word, address: banned.get('0x' + word.slice(26))});
      });
    }
  }
  return hits;
}

/** The runbook's constructor lines must agree with the table above (same words, same order). */
export function runbookWords(text) {
  const found = {};
  const re = /`([A-Za-z0-9_]+)\(([^`]*)\)` constructor words/g;
  let m;
  while ((m = re.exec(text)) !== null) found[m[1]] = m[2].split(',').map((s) => s.trim());
  return found;
}

if (process.argv[1] && import.meta.url === new URL(`file://${process.argv[1]}`).href) {
  const hits = checkWords(LAUNCHES);
  const runbook = readFileSync(new URL('../launch-v39.md', import.meta.url), 'utf8');
  const words = runbookWords(runbook);
  const mismatches = [];
  for (const contracts of Object.values(LAUNCHES)) {
    for (const [contract, expected] of Object.entries(contracts)) {
      if (!words[contract]) mismatches.push(`${contract}: no constructor line in launch-v39.md`);
      else if (words[contract].join(',') !== expected.join(',')) mismatches.push(`${contract}: launch-v39.md says (${words[contract].join(', ')}) but the gate table says (${expected.join(', ')})`);
    }
  }
  const runbookHits = checkWords(Object.fromEntries(Object.entries(words).map(([c, w]) => [c, {[c]: w}])));
  const all = [...hits, ...runbookHits];
  for (const h of all) console.error(`DEPLOY GATE: ${h.launch}/${h.contract} word ${h.index} = ${h.word} is the IMD ${h.address} address`);
  for (const m of mismatches) console.error(`RUNBOOK: ${m}`);
  if (all.length || mismatches.length) process.exit(1);
  const n = Object.values(LAUNCHES).reduce((a, c) => a + Object.keys(c).length, 0);
  console.log(`deploy gate: ${n} contracts in 4 launches, no constructor word equals an IMD protocol address; launch-v39.md agrees`);
}
