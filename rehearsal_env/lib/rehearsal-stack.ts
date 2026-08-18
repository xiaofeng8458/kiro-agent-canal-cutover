import * as cdk from 'aws-cdk-lib';
import { Construct } from 'constructs';
import * as ec2 from 'aws-cdk-lib/aws-ec2';
import * as eks from 'aws-cdk-lib/aws-eks';
import * as iam from 'aws-cdk-lib/aws-iam';
import * as msk from 'aws-cdk-lib/aws-msk';
import * as rds from 'aws-cdk-lib/aws-rds';
import { KubectlV35Layer } from '@aws-cdk/lambda-layer-kubectl-v35';

/**
 * 演练环境（EKS 版，成本最小化 + 基线安全实践）：
 *  - 不创建 VPC：必须通过 -c vpcId=vpc-xxx 指定现有 VPC，未提供直接报错
 *  - RDS for MySQL 8.0：primary + read replica（GTID ON，binlog 开启），私有隔离子网
 *  - EKS 1.35 + 1x t3.large 托管节点组：承载 ZK + canal-admin x2 + canal-server x1（生产同形态）
 *  - MSK provisioned kafka.t3.small x2：Canal 下游
 *  - t3.medium 跳板机（SSM 接入）：kubectl/mysql 运维操作点，与生产操作形态一致
 * 安全基线：
 *  - RDS/MSK 无公网访问、存储加密、SG 最小化（仅放行 EKS 节点与跳板机）
 *  - EKS 节点在私有子网（经 NAT 出网）；跳板机零 inbound、IMDSv2 强制、EBS 加密
 *  - 数据库凭证由 Secrets Manager 生成托管，代码中无明文
 */
export class CanalRehearsalStack extends cdk.Stack {
  constructor(scope: Construct, id: string, props?: cdk.StackProps) {
    super(scope, id, props);

    /* ---------------- 网络：必须使用现有 VPC（-c vpcId=vpc-xxx），不创建新 VPC ---------------- */
    const vpcId: string | undefined = this.node.tryGetContext('vpcId');
    if (!vpcId) {
      throw new Error(
        '缺少 VPC id：本栈不创建 VPC，必须指定现有 VPC。用法：npx cdk deploy -c vpcId=vpc-xxxxxxxxxxxxxxxxx',
      );
    }
    const vpc = ec2.Vpc.fromLookup(this, 'Vpc', { vpcId });

    // 子网选择（对现有 VPC 的形态做硬校验，不满足即报错）：
    //  - EKS 节点：private 子网（带 NAT 出网，拉镜像/访问控制面所需）
    //  - RDS/MSK：优先 isolated 子网，VPC 没有 isolated 时退用 private
    //  - 跳板机：优先 public，否则 private（SSM 经 NAT 仍可接入）
    if (vpc.privateSubnets.length === 0) {
      throw new Error(`VPC ${vpcId} 没有带 NAT 出网的 private 子网，EKS 节点组无法部署。`);
    }
    const appSubnets: ec2.SubnetSelection = { subnets: vpc.privateSubnets };

    const dataSubnetList = vpc.isolatedSubnets.length >= 2 ? vpc.isolatedSubnets : vpc.privateSubnets;
    // MSK 要求 2 个不同 AZ 的子网：每个 AZ 取一个
    const byAz = new Map<string, ec2.ISubnet>();
    for (const s of dataSubnetList) {
      if (!byAz.has(s.availabilityZone)) byAz.set(s.availabilityZone, s);
    }
    const mskSubnets = [...byAz.values()].slice(0, 2);
    if (mskSubnets.length < 2) {
      throw new Error(`VPC ${vpcId} 的 isolated/private 子网覆盖不足 2 个 AZ，无法部署 MSK（最少 2 AZ）。`);
    }
    const dataSubnets: ec2.SubnetSelection = { subnets: dataSubnetList };

    // 跳板机放 private 子网：SSM 经 NAT 出网注册，实例零公网暴露。
    // （public 子网方案依赖子网自动分配公网 IP，现有 VPC 常关闭该选项，SSM 会注册失败）
    const bastionSubnet: ec2.SubnetSelection = { subnets: [vpc.privateSubnets[0]] };

    /* ---------------- 安全组 ---------------- */
    const bastionSg = new ec2.SecurityGroup(this, 'BastionSg', {
      vpc,
      description: 'bastion: no inbound, access via SSM only',
      allowAllOutbound: true,
    });

    const rdsSg = new ec2.SecurityGroup(this, 'RdsSg', {
      vpc,
      description: 'rds mysql: 3306 from eks nodes and bastion only',
      allowAllOutbound: false,
    });

    const mskSg = new ec2.SecurityGroup(this, 'MskSg', {
      vpc,
      description: 'msk brokers: kafka ports from eks nodes and bastion only',
      allowAllOutbound: false,
    });

    rdsSg.addIngressRule(bastionSg, ec2.Port.tcp(3306), 'bastion to mysql');
    mskSg.addIngressRule(bastionSg, ec2.Port.tcp(9092), 'bastion to kafka plaintext');
    mskSg.addIngressRule(bastionSg, ec2.Port.tcp(9094), 'bastion to kafka tls');

    /* ---------------- RDS for MySQL：primary + reader，GTID ON ---------------- */
    const engine = rds.DatabaseInstanceEngine.mysql({
      version: rds.MysqlEngineVersion.of('8.0.42', '8.0'), // 贴近生产 8.0.4x；蓝绿升级目标 8.4 在演练时创建
    });

    const parameterGroup = new rds.ParameterGroup(this, 'GtidParams', {
      engine,
      description: 'GTID ON for canal blue/green rehearsal',
      parameters: {
        // 注意：RDS for MySQL 的参数名是 gtid-mode（连字符），与 MySQL 原生 gtid_mode 不同
        'gtid-mode': 'ON',
        enforce_gtid_consistency: 'ON',
        binlog_format: 'ROW',
      },
    });

    const dbInstanceType = ec2.InstanceType.of(ec2.InstanceClass.BURSTABLE4_GRAVITON, ec2.InstanceSize.MICRO);

    const primary = new rds.DatabaseInstance(this, 'Primary', {
      engine,
      instanceType: dbInstanceType, // db.t4g.micro：演练最小规格
      vpc,
      vpcSubnets: dataSubnets,
      securityGroups: [rdsSg],
      credentials: rds.Credentials.fromGeneratedSecret('dbadmin'), // Secrets Manager 托管
      parameterGroup,
      allocatedStorage: 20,
      storageType: rds.StorageType.GP3,
      storageEncrypted: true,
      multiAz: false, // 演练环境省成本；生产为 Multi-AZ
      backupRetention: cdk.Duration.days(1), // 必须 >0 才开启 binlog
      deleteAutomatedBackups: true,
      deletionProtection: false,
      removalPolicy: cdk.RemovalPolicy.DESTROY,
      publiclyAccessible: false,
      cloudwatchLogsExports: ['error'],
    });

    const reader = new rds.DatabaseInstanceReadReplica(this, 'Reader', {
      sourceDatabaseInstance: primary,
      instanceType: dbInstanceType,
      vpc,
      vpcSubnets: dataSubnets,
      securityGroups: [rdsSg],
      storageEncrypted: true,
      // 副本自身保留 binlog（canal 接入点与生产一致：订阅只读副本）
      backupRetention: cdk.Duration.days(1),
      deleteAutomatedBackups: true,
      deletionProtection: false,
      removalPolicy: cdk.RemovalPolicy.DESTROY,
      publiclyAccessible: false,
    });

    /* ---------------- MSK：最小 provisioned 集群 ---------------- */
    const mskCluster = new msk.CfnCluster(this, 'MskCluster', {
      clusterName: 'canal-rehearsal',
      kafkaVersion: '3.6.0',
      numberOfBrokerNodes: 2, // provisioned 最小值（2 AZ）
      brokerNodeGroupInfo: {
        instanceType: 'kafka.t3.small',
        clientSubnets: mskSubnets.map((s) => s.subnetId), // 每 AZ 一个，共 2 个
        securityGroups: [mskSg.securityGroupId],
        storageInfo: { ebsStorageInfo: { volumeSize: 20 } },
      },
      encryptionInfo: {
        // 存储加密默认开启（AWS 托管 KMS）；VPC 内演练允许 PLAINTEXT 便于 canal 直连 9092
        encryptionInTransit: { clientBroker: 'TLS_PLAINTEXT', inCluster: true },
      },
    });

    /* ---------------- EKS：控制面 + 1x t3.large 托管节点组 ---------------- */
    const cluster = new eks.Cluster(this, 'RehearsalEks', {
      clusterName: 'canal-rehearsal',
      version: eks.KubernetesVersion.V1_35, // 1.33 标准支持 2026-07-30 到期，直接上 1.35
      kubectlLayer: new KubectlV35Layer(this, 'KubectlLayer'),
      vpc,
      vpcSubnets: [appSubnets],
      defaultCapacity: 0, // 用显式节点组，便于控制规格与 IAM
      endpointAccess: eks.EndpointAccess.PUBLIC_AND_PRIVATE, // 生产建议 PRIVATE 或限制 CIDR
      outputClusterName: true,
    });

    const nodeRole = new iam.Role(this, 'NodeRole', {
      assumedBy: new iam.ServicePrincipal('ec2.amazonaws.com'),
      managedPolicies: [
        iam.ManagedPolicy.fromAwsManagedPolicyName('AmazonEKSWorkerNodePolicy'),
        iam.ManagedPolicy.fromAwsManagedPolicyName('AmazonEKS_CNI_Policy'),
        iam.ManagedPolicy.fromAwsManagedPolicyName('AmazonEC2ContainerRegistryReadOnly'),
      ],
    });

    cluster.addNodegroupCapacity('Nodes', {
      instanceTypes: [ec2.InstanceType.of(ec2.InstanceClass.T3, ec2.InstanceSize.LARGE)], // x86：canal 官方镜像 amd64
      amiType: eks.NodegroupAmiType.AL2023_X86_64_STANDARD, // EKS 1.33 起不支持 AL2（CDK 默认值），须显式 AL2023
      minSize: 1,
      maxSize: 1,
      desiredSize: 1,
      diskSize: 30,
      nodeRole,
      subnets: appSubnets,
    });

    // EBS CSI 的凭证走 EKS Pod Identity（节点 IMDS hop limit=1，容器取不到节点角色凭证，
    // 这是预期的安全默认值；给 CSI controller 专属角色是官方推荐做法）
    const ebsCsiRole = new iam.Role(this, 'EbsCsiRole', {
      assumedBy: new iam.ServicePrincipal('pods.eks.amazonaws.com'),
      managedPolicies: [
        iam.ManagedPolicy.fromAwsManagedPolicyName('service-role/AmazonEBSCSIDriverPolicy'),
      ],
    });
    ebsCsiRole.assumeRolePolicy!.addStatements(new iam.PolicyStatement({
      effect: iam.Effect.ALLOW,
      principals: [new iam.ServicePrincipal('pods.eks.amazonaws.com')],
      actions: ['sts:TagSession'], // Pod Identity 除 AssumeRole 外还需要 TagSession
    }));

    const podIdentityAgent = new eks.CfnAddon(this, 'PodIdentityAgentAddon', {
      addonName: 'eks-pod-identity-agent',
      clusterName: cluster.clusterName,
      resolveConflicts: 'OVERWRITE',
    });

    // EBS CSI 驱动（EKS >=1.23 动态 PVC 必需，ZK 的 volumeClaimTemplates 依赖它）
    const ebsCsiAddon = new eks.CfnAddon(this, 'EbsCsiAddon', {
      addonName: 'aws-ebs-csi-driver',
      clusterName: cluster.clusterName,
      resolveConflicts: 'OVERWRITE',
      podIdentityAssociations: [{
        roleArn: ebsCsiRole.roleArn,
        serviceAccount: 'ebs-csi-controller-sa',
      }],
    });
    ebsCsiAddon.addDependency(podIdentityAgent);

    // 跳板机 kubectl 访问 EKS API：VPC 内域名解析到控制面私网 ENI，须放行 443（否则 i/o timeout）
    cluster.connections.allowFrom(bastionSg, ec2.Port.tcp(443), 'bastion kubectl to eks api');

    // EKS 节点 to RDS / MSK（托管节点组挂载 cluster security group）
    rdsSg.addIngressRule(cluster.clusterSecurityGroup, ec2.Port.tcp(3306), 'eks nodes to mysql');
    mskSg.addIngressRule(cluster.clusterSecurityGroup, ec2.Port.tcp(9092), 'eks nodes to kafka plaintext');
    mskSg.addIngressRule(cluster.clusterSecurityGroup, ec2.Port.tcp(9094), 'eks nodes to kafka tls');

    /* ---------------- 跳板机：kubectl/mysql 运维操作点（SSM 接入，零 inbound） ---------------- */
    const bastionRole = new iam.Role(this, 'BastionRole', {
      assumedBy: new iam.ServicePrincipal('ec2.amazonaws.com'),
      managedPolicies: [
        iam.ManagedPolicy.fromAwsManagedPolicyName('AmazonSSMManagedInstanceCore'),
      ],
    });
    primary.secret!.grantRead(bastionRole); // 读取 DB 凭证做初始化
    bastionRole.addToPolicy(new iam.PolicyStatement({
      actions: ['kafka:GetBootstrapBrokers', 'kafka:DescribeCluster'],
      resources: [mskCluster.attrArn],
    }));
    bastionRole.addToPolicy(new iam.PolicyStatement({
      actions: ['eks:DescribeCluster'], // aws eks update-kubeconfig 所需
      resources: [cluster.clusterArn],
    }));
    // 跳板机角色获得集群管理权限（写入 aws-auth，kubectl 直接可用）
    cluster.awsAuth.addMastersRole(bastionRole, 'bastion');

    const userData = ec2.UserData.forLinux();
    userData.addCommands(
      'dnf install -y mariadb105 jq git',
      // kubectl（与集群版本匹配）
      'curl -sL -o /usr/local/bin/kubectl "https://dl.k8s.io/release/v1.35.0/bin/linux/amd64/kubectl"',
      'chmod +x /usr/local/bin/kubectl',
      `echo 'aws eks update-kubeconfig --name ${cluster.clusterName} --region ${this.region}  # 首次登录执行' > /etc/motd`,
    );

    const bastion = new ec2.Instance(this, 'Bastion', {
      vpc,
      vpcSubnets: bastionSubnet, // private 子网 + 零 inbound + SSM 接入
      securityGroup: bastionSg,
      // t3.micro(1GB) 实证扛不住 Kiro CLI 会话 + kubectl 常驻（内存耗尽宕机重启），
      // 演练期用 t3.medium；纯脚本运维可降回 small
      instanceType: ec2.InstanceType.of(ec2.InstanceClass.T3, ec2.InstanceSize.MEDIUM),
      machineImage: ec2.MachineImage.latestAmazonLinux2023(),
      role: bastionRole,
      requireImdsv2: true,
      blockDevices: [{
        deviceName: '/dev/xvda',
        volume: ec2.BlockDeviceVolume.ebs(10, {
          encrypted: true,
          volumeType: ec2.EbsDeviceVolumeType.GP3,
          deleteOnTermination: true,
        }),
      }],
      userData,
    });

    /* ---------------- 输出 ---------------- */
    new cdk.CfnOutput(this, 'PrimaryEndpoint', { value: primary.instanceEndpoint.hostname });
    new cdk.CfnOutput(this, 'ReaderEndpoint', { value: reader.instanceEndpoint.hostname });
    new cdk.CfnOutput(this, 'DbSecretName', { value: primary.secret!.secretName });
    new cdk.CfnOutput(this, 'MskClusterArn', { value: mskCluster.attrArn });
    new cdk.CfnOutput(this, 'BastionId', { value: bastion.instanceId });
    new cdk.CfnOutput(this, 'SsmConnect', {
      value: `aws ssm start-session --target ${bastion.instanceId} --region ${this.region}`,
    });
    new cdk.CfnOutput(this, 'MskBootstrapCmd', {
      value: `aws kafka get-bootstrap-brokers --cluster-arn ${mskCluster.attrArn} --region ${this.region}`,
    });
  }
}
