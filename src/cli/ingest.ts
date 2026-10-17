import { IngestService } from "../services/ingest.service.js";
import { CensusGazetteerAdapter } from "../adapters/census-gazetteer.adapter.js";
import { HudUspsAdapter } from "../adapters/hud-usps.adapter.js";
import { CensusAcsAdapter } from "../adapters/census-acs.adapter.js";
import { BeaRegionalRppAdapter } from "../adapters/bea-regional.adapter.js";
import { BtsFafAdapter } from "../adapters/bts-faf.adapter.js";
import { FreightReferenceAdapter } from "../adapters/freight-reference.adapter.js";
import { redact } from "../core/redaction.js";

const [source,...rest]=process.argv.slice(2);if(!source)throw new Error("Usage: ingest <source> [args]");
let adapter;
switch(source){
 case "gazetteer-state":adapter=new CensusGazetteerAdapter("STATE",Number(rest[0]??2026));break;
 case "gazetteer-county":adapter=new CensusGazetteerAdapter("COUNTY",Number(rest[0]??2026));break;
 case "gazetteer-place":adapter=new CensusGazetteerAdapter("PLACE",Number(rest[0]??2026));break;
 case "gazetteer-zcta":adapter=new CensusGazetteerAdapter("ZCTA",Number(rest[0]??2026));break;
 case "hud-zip-county":adapter=new HudUspsAdapter(2,Number(rest[0]),Number(rest[1]) as 1|2|3|4);break;
 case "hud-zip-cbsa":adapter=new HudUspsAdapter(3,Number(rest[0]),Number(rest[1]) as 1|2|3|4);break;
 case "acs-state":adapter=new CensusAcsAdapter(Number(rest[0]??2024),"STATE",["DP05_0001E","DP03_0062E","DP03_0128PE","DP04_0001E"]);break;
 case "acs-county":adapter=new CensusAcsAdapter(Number(rest[0]??2024),"COUNTY",["DP05_0001E","DP03_0062E","DP03_0128PE","DP04_0001E"]);break;
 case "acs-place":adapter=new CensusAcsAdapter(Number(rest[0]??2024),"PLACE",["DP05_0001E","DP03_0062E","DP03_0128PE","DP04_0001E"]);break;
 case "acs-zcta":adapter=new CensusAcsAdapter(Number(rest[0]??2024),"ZCTA",["DP05_0001E","DP03_0062E","DP03_0128PE","DP04_0001E"]);break;
 case "bea-rpp-state":{const year=Number(rest[0]);const table=rest[1];const line=rest[2];if(!year||!table||!line)throw new Error("Usage: ingest bea-rpp-state <year> <metadata-verified-tableName> <lineCode>");adapter=new BeaRegionalRppAdapter(year,table,line,"STATE");break;}
 case "bea-rpp-msa":{const year=Number(rest[0]);const table=rest[1];const line=rest[2];if(!year||!table||!line)throw new Error("Usage: ingest bea-rpp-msa <year> <metadata-verified-tableName> <lineCode>");adapter=new BeaRegionalRppAdapter(year,table,line,"MSA");break;}
 case "faf6":adapter=new BtsFafAdapter(rest[0]??"FAF6.0",Number(rest[1]??2022),rest[2]??process.env.BTS_FAF6_URL??"");break;
 case "faf6-zone":{const release=rest[0];const year=Number(rest[1]);const url=rest[2]??process.env.BTS_FAF6_ZONE_LOOKUP_URL??"";if(!release||!year)throw new Error("Usage: ingest faf6-zone <release> <year> <approved-zip-url>");adapter=new FreightReferenceAdapter("BTS_FAF6_ZONE_LOOKUP",release,year,url);break;}
 case "sctg":{const release=rest[0];const year=Number(rest[1]);const url=rest[2]??process.env.BTS_SCTG_METADATA_URL??"";if(!release||!year)throw new Error("Usage: ingest sctg <release> <year> <approved-zip-url>");adapter=new FreightReferenceAdapter("BTS_SCTG_METADATA",release,year,url);break;}
 case "cbp-county":{const year=Number(rest[0]);const url=rest[1]??process.env.CENSUS_CBP_URL??"";if(!year)throw new Error("Usage: ingest cbp-county <year> <approved-zip-url>");adapter=new FreightReferenceAdapter("CENSUS_CBP",`${year}:COUNTY`,year,url);break;}
 default:throw new Error(`Unknown source:${source}`);
}
new IngestService().run(adapter).then(x=>console.log(JSON.stringify(x,null,2))).catch(e=>{console.error(redact(e));process.exit(1);});
