% Original synthetic two-bus study fixture; no real operator data.
function mpc = synthetic_status_source
mpc.version = '2';
mpc.baseMVA = 100;
mpc.bus = [
1 3 0 0 0 0 1 1 0 110 1 1.1 0.9;
2 1 30 12 0 0 1 1 0 110 1 1.1 0.9;
];
mpc.gen = [
1 30 12 100 -100 1 100 1 100 0;
];
mpc.branch = [
1 2 0.01 0.1 0 100 100 100 0 0 1 -60 60;
];
mpc.gencost = [
2 0 0 3 0.01 1 0;
];
