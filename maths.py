from sympy import symbols, Eq, solve
import MF_Algebra as mfa

# 1. Définition de la variable symbolique
x = symbols('x')

# 2. Création d'une équation : 2x + 5 = 15
equation = Eq(2 * x + 5, 15)

# 3. Résolution mathématique
solution = solve(equation, x)

print(f"--- Équation à résoudre ---")
print(equation)

print("\n--- Solution ---")
print(f"x = {solution[0]}")