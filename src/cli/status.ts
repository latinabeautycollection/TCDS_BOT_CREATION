import{pool}from'../repositories/db.js';console.log(JSON.stringify((await pool.query('SELECT * FROM zsl.zsl3_current_authority')).rows,null,2));await pool.end();
