# Operator splitting

A short note on solving quadratic programs with *first-order* methods,
**warm starting**, and ~~slow~~ fast linear algebra. See [OSQP](https://osqp.org).

## Problem

We consider the problem with variable $x \in \mathbf{R}^n$ and data $P \in \mathbf{S}^n_+$, $q$, $A$, and $b$, where $\frac{1}{2}$ is inline:

$$
\begin{array}{ll}
\text{minimize} & (1/2)x^TPx + q^Tx \\
\text{subject to} & Ax = b, \quad x \ge 12
\end{array}
$$

The optimal value is $p^\star = \inf_x \{ f(x) \mid Ax = b \}$.

### Algorithm

- First point
- Second point

1. Factor the KKT matrix
2. Iterate until `tol < 1e-4`
   - nested item
     - third level
   - [ ] open task
   - [x] done task

> Convergence is linear under strong convexity.
> The rate depends on $\kappa$.

```python
import cvxpy as cp

def solve(P, q, A, b):
    """Solve a small QP."""
    x = cp.Variable(P.shape[0])
    cost = 0.5 * cp.quad_form(x, P) + q @ x  # objective
    prob = cp.Problem(cp.Minimize(cost), [A @ x == b, x >= 0])
    return prob.solve(solver="OSQP", eps_abs=1e-4)
```

```sh
for f in *.md; do echo "rendering $f"; done
```

```lua
local n = 10 -- highlighted by treesitter
print(("n = %d"):format(n))
```

| Solver | Time (s) | Iterations |
|--------|---------:|:----------:|
| OSQP | 0.12 | 50 |
| Clarabel | 0.3 | 12 |

---

```math
\int_0^\infty e^{-x^2}\,dx = \frac{\sqrt{\pi}}{2}
```

A broken formula $\frac{a$ shows an error.
