# IAM Portfolio

Hands-on identity and access management projects, built and tested in a Microsoft Entra ID lab tenant.

## About me

I'm an IAM engineer with an M.S. in Cybersecurity Management. I hold the **Microsoft SC-300 (Identity and Access Administrator)** and **CompTIA Security+** certifications. I focus on securing identities: automating the user lifecycle, enforcing least privilege with Conditional Access, connecting apps through SSO, and managing identity configuration as code.

This repo collects projects that show how I design, build and document IAM controls.

## Projects

| # | Project | Description | Status |
|---|---------|-------------|--------|
| 01 | [Bulk User Provisioning](./01-bulk-user-provisioning) | PowerShell + Graph script that runs joiner-mover-leaver from an HR CSV for 40 users, with dry-run and audit logging. | In progress |
| 02 | [Conditional Access Baseline](./02-conditional-access-baseline) | 8 CA policies rolled out report-only first, impact measured with KQL, then enforced. | Planned |
| 03 | [SSO with SAML and OIDC](./03-sso-saml-oidc) | One SAML and one OIDC app integrated with Entra ID, with annotated tokens and troubleshooting write-ups. | Planned |
| 04 | [Access Review Program](./04-access-review-program) | Quarterly access reviews and PIM for a fake company, ending in an audit-ready evidence pack mapped to NIST AC-2/AC-6. | Planned |
| 05 | [IAM as Code Pipeline](./05-iam-as-code-pipeline) | Groups, CA policies and app registrations in Terraform, deployed by GitHub Actions with PR review and nightly drift detection. | Planned |

All projects use one fictional company, **Contoso Logistics**, with Finance, Sales, IT and Operations departments.

## Tech stack

- **Identity platform:** Microsoft Entra ID (P2 features)
- **Access controls:** Conditional Access, Identity Governance, Access Reviews, Privileged Identity Management (PIM)
- **Monitoring and analysis:** KQL (Kusto Query Language) over Entra sign-in and audit logs
- **Protocols:** SAML 2.0, OAuth 2.0, OpenID Connect
- **Automation:** PowerShell, Microsoft Graph API
- **Infrastructure as code and CI/CD:** Terraform, GitHub Actions

## Contact

- LinkedIn: [aderibigbeademola100](https://www.linkedin.com/in/aderibigbeademola100/)
- GitHub: [Demo411](https://github.com/Demo411)
