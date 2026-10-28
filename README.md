# ORCA ωB97M(2) two-body interaction energies with counterpoise correction

These Bash scripts generate and run ORCA compound jobs for a set of dimer geometries, then collect the dimer and counterpoise-corrected interaction energies. The supplied templates use a ωB97M-V SCF step to prepare orbitals, followed by a ωB97M(2) step, with the `def2-TZVPP` basis. They are configured for an **8-atom, neutral singlet** example and require editing before use on another system.

## Files and workflow

- `run_bsse_orca.sh` reads selected frames from a multi-frame XYZ file, builds numbered ORCA inputs, and runs up to `k` jobs concurrently.
- `H` and `T` form the beginning and end of each ORCA `%Compound` input. 
  `H` sets the method, basis, charge, multiplicity, parallel resources, and final energy expression.
- `B1`–`B3` define the ωB97M-V SCF steps for the dimer, monomer A in the dimer basis, and monomer B in the dimer basis. `C1`–`C3` define the matching ωB97M(2) steps using the saved orbitals. Each SCF step is followed by its ωB97M(2) step.
- `orcacatcher3.sh` reads the final counterpoise summary from each numbered `.out` file and the geometry from its matching `.inp` file. It writes energy lists, a TSV table, and XYZ trajectories whose comment lines contain the energies.
- `coordinate.xyz` is a **placeholder** showing the required multi-frame layout; replace its bracketed atom names and coordinates with real data.

For each frame, the runner uses the full geometry for the dimer. It replaces monomer B's atoms with ORCA ghost atoms for the monomer A calculation, and replaces monomer A's atoms with ghosts for the monomer B calculation. The compound input reports the interaction energy as `(E_AB - E_A - E_B) × 219480` in `cm**-1`; the dimer energy is reported in atomic units. The factor `219480` is defined in `H` and can be changed if a different conversion precision is needed.

## Requirements

- Linux or another Unix-like environment with Bash, `awk`, `mkfifo`, and standard shell utilities. The collector also requires `tac`, `find`, `mktemp`, and GNU `sort` with `-V` and `-z` support.
- An installed ORCA executable compatible with the keywords and `%Compound` syntax in the templates. Parallel jobs also need the MPI environment required by that ORCA installation.
- Enough allocated CPU cores and memory for all concurrent jobs. The supplied settings request 6 ORCA processes and `%maxcore 1000` for each job; with `k=4`, plan for up to 24 processes plus suitable memory headroom.

## Adapt the inputs to your system

1. **Prepare geometries.** Make a multi-frame XYZ file with the same number and order of atoms in every frame. Each frame must contain exactly an atom-count line, a comment line, and `natom` coordinate lines. The runner uses 1-based frame numbers and expects exactly `natom + 2` lines per frame. Plain `Element x y z` coordinate lines work; use actual element symbols and numeric coordinates.
2. **Set atom counts and fragments in `run_bsse_orca.sh`.** Set `natom` to the atoms per frame. Set `lines_A` to the **1-based atom indices of monomer B**, which are turned into ghosts when calculating monomer A. Set `lines_B` to the **1-based atom indices of monomer A**, which are turned into ghosts when calculating monomer B. In the supplied 8-atom example, atoms 1–7 form A and atom 8 forms B, so `lines_A="8"` and `lines_B="1 2 3 4 5 6 7"`. Check that the two lists cover the intended fragments without overlap.
3. **Set ORCA and MPI paths in `run_bsse_orca.sh`.** Replace the site-specific `PATH`, `LD_LIBRARY_PATH`, and `ORCA` assignments at the top of the script with paths for your installation. `ORCA` must point to an executable file. Adjust `k` (simultaneous jobs), `pause` (seconds between launches), and `stop_grace` (shutdown wait) as needed.
4. **Review the chemistry and resources in `H` and `B1`–`C3`.** `H` contains `basis`, `auxJ`, `auxC`, `charge`, `mult`, `%pal nprocs 6`, and `%maxcore 1000`. The same `charge` and `mult` are used for dimer and both monomers; systems needing different fragment charges or multiplicities require changes to the templates. Review the method, basis, grids, SCF settings, and conversion factor for your calculation. Keep the six step files and their aliases consistent if you edit the compound workflow.
5. **Keep the template files together.** Run from a directory containing `H`, `T`, `B1`–`B3`, and `C1`–`C3`. `head_file` and `tail_file` in the runner point to `H` and `T` by default.

## Run

From the directory containing the templates and your geometry file:

```bash
bash run_bsse_orca.sh geometries.xyz 1 10
```

This processes frames 1 through 10, inclusive. For frame `i`, it creates `i.inp` and `i.out`, checks for `ORCA TERMINATED NORMALLY`, and removes selected ORCA auxiliary files. It prints a failure message and returns a nonzero status if any job fails. Run in a dedicated working directory: numbered inputs and outputs, `ignore.log`, and some auxiliary files can be overwritten or removed by the runner.

After the calculations finish, collect the energies:

```bash
bash orcacatcher3.sh --prefix my_system
```

The collector processes `*.out` in natural order (`1.out`, `2.out`, `10.out`) and requires a matching `.inp` for each output. It writes:

| File | Contents |
| --- | --- |
| `my_system_dimer_energy_list.dat` | One dimer energy per frame, in atomic units |
| `my_system_interaction_energy_list.dat` | One counterpoise-corrected interaction energy per frame, in `cm**-1` |
| `my_system_energies.tsv` | Output filename and both energies |
| `my_system_dimer_energy.xyz` | Geometries with dimer energies as XYZ comments |
| `my_system_interaction_energy.xyz` | Geometries with interaction energies as XYZ comments |

Use `bash orcacatcher3.sh --help` for all options. Useful ones include `--input-dir DIR`, `--glob PATTERN` to select a subset of `.out` files, `--head-lines NUMBER` if the first geometry is farther than 120 lines into an input, and `--skip-invalid` to omit incomplete files. `--delete-inputs` removes successfully merged `.inp` files **after** the result files are written; leave it off if you want to retain the inputs.

The collector expects the final `BSSE COUNTERPOISE CORRECTION SUMMARY` block and the labels `Dimer energy` and `Interaction energy` produced by `T`. If you change those labels, update the collector's keys or pass `--summary-key`, `--dimer-key`, and `--interaction-key`. It does not recompute energies; inspect the ORCA outputs and confirm the method and units before using the results.
