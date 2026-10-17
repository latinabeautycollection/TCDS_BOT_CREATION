import { CertificationService } from "../services/certification.service.js";
const id=process.argv[2];if(!id)throw new Error("Usage: certify <ingestRunId>");
new CertificationService().certify(id).then(console.log).catch(e=>{console.error(e);process.exit(1);});
