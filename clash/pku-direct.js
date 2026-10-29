// Clash Verge Rev 2.x global extension script.
//
// Keeps PKU VPN, campus, and library traffic outside the proxy while Clash
// serves general Internet access. Add missing databases to academicRules.

function main(config, profileName) {
  const pkuRules = [
    "DOMAIN-SUFFIX,vpn.pku.edu.cn,DIRECT",
    "DOMAIN-SUFFIX,pacvpn.pku.edu.cn,DIRECT",
    "DOMAIN-SUFFIX,arrayvpn.pku.edu.cn,DIRECT",
    "DOMAIN-SUFFIX,pku.edu.cn,DIRECT",
    "IP-CIDR,162.105.0.0/16,DIRECT,no-resolve",
    "IP-CIDR,222.29.0.0/16,DIRECT,no-resolve",
    "IP-CIDR,202.112.0.0/16,DIRECT,no-resolve",
    "IP-CIDR,10.0.0.0/8,DIRECT,no-resolve",
    "IP-CIDR,172.16.0.0/12,DIRECT,no-resolve",
  ];

  const academicRules = [
    // Elsevier / Springer / Nature / Wiley
    "DOMAIN-SUFFIX,sciencedirect.com,DIRECT",
    "DOMAIN,brunhild.challenges.cloudflare.com,DIRECT",
    "DOMAIN-SUFFIX,sciencedirectassets.com,DIRECT",
    "DOMAIN-SUFFIX,elsevier.com,DIRECT",
    "DOMAIN-SUFFIX,springer.com,DIRECT",
    "DOMAIN-SUFFIX,springerlink.com,DIRECT",
    "DOMAIN-SUFFIX,springernature.com,DIRECT",
    "DOMAIN-SUFFIX,nature.com,DIRECT",
    "DOMAIN-SUFFIX,biomedcentral.com,DIRECT",
    "DOMAIN-SUFFIX,wiley.com,DIRECT",
    "DOMAIN-SUFFIX,cell.com,DIRECT",
    "DOMAIN-SUFFIX,theclinics.com,DIRECT",
    // Taylor & Francis / SAGE / OUP / CUP
    "DOMAIN-SUFFIX,tandfonline.com,DIRECT",
    "DOMAIN-SUFFIX,sagepub.com,DIRECT",
    "DOMAIN-SUFFIX,oup.com,DIRECT",
    "DOMAIN-SUFFIX,cambridge.org,DIRECT",
    // Engineering / computer science
    "DOMAIN-SUFFIX,ieee.org,DIRECT",
    "DOMAIN-SUFFIX,acm.org,DIRECT",
    "DOMAIN-SUFFIX,springerprofessional.de,DIRECT",
    // Aggregators / indexes / DOI
    "DOMAIN-SUFFIX,jstor.org,DIRECT",
    "DOMAIN-SUFFIX,ebsco.com,DIRECT",
    "DOMAIN-SUFFIX,proquest.com,DIRECT",
    "DOMAIN-SUFFIX,webofscience.com,DIRECT",
    "DOMAIN-SUFFIX,clarivate.com,DIRECT",
    "DOMAIN-SUFFIX,scopus.com,DIRECT",
    "DOMAIN-SUFFIX,researchgate.net,DIRECT",
    "DOMAIN-SUFFIX,semanticscholar.org,DIRECT",
    "DOMAIN-SUFFIX,doi.org,DIRECT",
    "DOMAIN-SUFFIX,arxiv.org,DIRECT",
    "DOMAIN-SUFFIX,ncbi.nlm.nih.gov,DIRECT",
    // Societies / reviews
    "DOMAIN-SUFFIX,aps.org,DIRECT",
    "DOMAIN-SUFFIX,iop.org,DIRECT",
    "DOMAIN-SUFFIX,rsc.org,DIRECT",
    "DOMAIN-SUFFIX,acs.org,DIRECT",
    "DOMAIN-SUFFIX,ams.org,DIRECT",
    "DOMAIN-SUFFIX,annualreviews.org,DIRECT",
    // Chinese databases
    "DOMAIN-SUFFIX,cnki.net,DIRECT",
    "DOMAIN-SUFFIX,cnki.com.cn,DIRECT",
    "DOMAIN-SUFFIX,wanfangdata.com.cn,DIRECT",
    "DOMAIN-SUFFIX,cqvip.com,DIRECT",
    "DOMAIN-SUFFIX,chineserp.com,DIRECT",
  ];

  const existing = Array.isArray(config.rules) ? config.rules : [];
  const wanted = [...pkuRules, ...academicRules];
  const missing = wanted.filter((rule) => !existing.includes(rule));
  config.rules = [...missing, ...existing];

  if (config.dns) {
    const filter = Array.isArray(config.dns["fake-ip-filter"])
      ? config.dns["fake-ip-filter"]
      : [];
    if (!filter.includes("+.pku.edu.cn")) {
      config.dns["fake-ip-filter"] = [...filter, "+.pku.edu.cn"];
    }

    const policy = config.dns["nameserver-policy"] || {};
    if (!policy["+.pku.edu.cn"]) {
      policy["+.pku.edu.cn"] = ["system"];
    }
    config.dns["nameserver-policy"] = policy;
  }

  return config;
}
