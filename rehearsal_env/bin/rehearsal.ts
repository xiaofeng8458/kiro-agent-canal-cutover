#!/usr/bin/env node
import * as cdk from 'aws-cdk-lib';
import { CanalRehearsalStack } from '../lib/rehearsal-stack';

const app = new cdk.App();

// 缺省部署到 us-east-1；可用 -c region=xx 覆盖
const region = app.node.tryGetContext('region') ?? 'us-east-1';

new CanalRehearsalStack(app, 'CanalRehearsalStack', {
  env: { account: process.env.CDK_DEFAULT_ACCOUNT, region },
  description: 'Canal blue/green rehearsal for RDS for MySQL 8.0->8.4: RDS MySQL primary+reader, k3s canal (ZK + 2 admin + 1 server), MSK',
});

cdk.Tags.of(app).add('project', 'canal-mysql84-rehearsal');
cdk.Tags.of(app).add('lifecycle', 'ephemeral');
