# KipuBank v2

## Descripción

KipuBank v2 permite a los usuarios depositar y retirar tanto ETH como tokens ERC-20 (por ejemplo, USDC).
Toda la contabilidad interna se lleva en USD, utilizando un oráculo Chainlink para obtener el precio ETH/USD en tiempo real.

## Mejoras principales

* **Multi-Token**: se admite ETH (usando `address(0)`) y ERC-20 como USDC.
* **Contabilidad en USD**: todos los montos se convierten a dólares según el oráculo.
* **Control de acceso**: uso de `Ownable` para funciones administrativas.
* **Seguridad**: uso de `Checks-Effects-Interactions` y `nonReentrant`.
* **Eventos y errores personalizados**: mejoran la trazabilidad y depuración.

## Decisiones de diseño

Para simplificar los cálculos internos, como los límites de bóveda, el depósito y retiro de fondos, se utilizan USD.
Además, ahora solo el propietario del contrato puede cambiar el oráculo y agregar o quitar monedas.
Se utilizan librerias estándar de OpenZeppelin para la confiabilidad en el trato de monedas ERC-20, así como estas medidas de propietario.
Para mantener los precios al día, se utiliza Chainlink.

## Despliegue
### Requisitos

* Remix IDE (remix.ethereum.org)
* Contar con fondos en una testnet (por ejemplo, Sepolia)
* Direcciones de contrato de USDC y del feed ETH/USD de Chainlink

### Constructor

```solidity
constructor(
    uint256 maxWithdrawal,
    uint256 maxVaultUSD,
    address _usdc,
    address _feed
)
```

### Ejemplo (en Sepolia)

```solidity
KipuBank bank = new KipuBank(
    1_000 * 1e6, // retiro máximo: 1000 USDC
    10_000 * 1e6, // límite máximo por usuario: 10.000 USDC
    0x1B1B5f6fB9C2E2b8aE2464aF2dC2E2e5Dcd4DDBF, // USDC
    0x694AA1769357215DE4FAC081bf1f309aDC325306 // ETH/USD feed
);
```

## Interacción

* **Depositar ETH:** `deposit()` (payable)
* **Depositar tokens:** `depositToken(address token, uint256 amount)`
* **Retirar fondos:** `withdrawal(address token, uint256 amount)`
* **Consultar saldo:** `viewVault(address token)`
* **Actualizar oráculo:** `setFeed(address newFeed)` *(solo owner)*

## Ejemplo de uso

```solidity
// Depositar 0.1 ETH
kipuBank.deposit{value: 0.1 ether}();

// Consultar valor en USD del depósito
uint256 usdValue = kipuBank.ethDepositValueInUSD(0.1 ether);

// Retirar 50 USDC
kipuBank.withdrawal(usdcAddress, 50e6);
```
