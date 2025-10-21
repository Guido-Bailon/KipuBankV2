// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.2;

/*///////////////////////
        Imports
///////////////////////*/
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";


/*///////////////////////
        Libraries
///////////////////////*/
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/*///////////////////////
        Interfaces
///////////////////////*/
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

contract KipuBank is ReentrancyGuard, Ownable {
    /*///////////////////////
					Declaracion de tipos
	///////////////////////*/
    using SafeERC20 for IERC20;


    /*///////////////////////
					Variables
	///////////////////////*/
    ///@notice constante que indica el maximo valor almacenable de eth para todos los usuarios en USD
    uint256 immutable BANK_CAP_USD;
    ///@notice variable inmutable que indica la maxima cantidad de eth que pueden retirarse en una unica transaccion
    uint256 immutable i_maxWithdrawal;
    ///@notice variable utilizada para almacenar la boveda de cada usuario, donde el primer address es ETH y el segundo address es el usuario
    mapping(address token => mapping(address user => uint256 vault)) private s_vaults;
    ///@notice mapping que almacena los tokens aceptados por el banco
    mapping(address token => bool exists) private s_tokens;
    ///@notice variable que almacena la cantidad total de depositos
    uint128 private s_deposits;
    ///@notice variable que almacena la cantidad total de retiros
    uint128 private s_withdrawals;
    ///@notice variable inmutable que almacena la direccion del token USDC
    IERC20 immutable i_usdc;
    ///@notice variable que almacena la direccion del feed de Chainlink para el precio de ETH/USD
    AggregatorV3Interface public s_feed;
    
    /*///////////////////////
					Events
	///////////////////////*/
    ///@notice evento emitido cuando un usuario realiza un deposito correctamente para un token
    event KipuBank_deposit(address user,address token, uint256 value);
    ///@notice evento emitido cuando un usuario realiza un retiro correctamente para un token
    event KipuBank_withdrawal(address user, address token, uint256 value);
    ///@notice evento emitido cuando se actualiza la direccion del feed de Chainlink
    event KipuBank_feedUpdated(address feed);
    ///@notice evento emitido cuando se agrega un token al banco
    event KipuBank_tokenAdded(address token);
    ///@notice evento emitido cuando se elimina un token del banco
    event KipuBank_tokenRemoved(address token);

    /*///////////////////////
					Errors
	///////////////////////*/
    ///@notice error emitido cuando un usuario quiere depositar y fuera a superar el maximo de su boveda
    error KipuBank_bankCapped(address caller, address token);
    ///@notice error emitido cuando un usuario quiere retirar mas fondos de los que posee en su boveda
    error KipuBank_unsuficentFunds(address caller, address token);
    ///@notice error emitido cuando un usuario quiere retirar mas fondos de lo permitido por el banco
    error KipuBank_withdrawalCapped(address caller, address token);
    ///@notice error emitido un retiro falla
    error KipuBank_withdrawalFailed(address caller, address token);
    ///@notice error emitido cuando un usuario intenta interactuar con un token que no existe
    error KipuBank_nonExistentToken(address token);
    ///@notice error emitido cuando hay un problema con el oraculo de precios
    error KipuBank_OracleError();
    ///@notice error emitido cuando el precio obtenido del oraculo esta desactualizado
    error KipuBank_StalePrice();

    /*///////////////////////
					Functions
	///////////////////////*/

    constructor(address _owner,uint256 maxWithdrawal, uint256 maxVault, address _usdc, address _feed) Ownable(_owner) {
        i_maxWithdrawal = maxWithdrawal;
        BANK_CAP_USD = maxVault * 1e8; //USD tiene 8 decimales
        i_usdc = IERC20(_usdc);
        s_feed = AggregatorV3Interface(_feed);
    }

    receive() external payable {
        _deposit(msg.sender, address(0), msg.value);
    }

    fallback() external payable{}

    /*
    @notice funcion privada que actualiza la boveda de un usuario a un nuevo valor
    */
    function _updateVault(address user,address token, uint256 newBalance) private {
        s_vaults[token][user] = newBalance;
    }

    /*
    @notice funcion interna que permite a un usuario depositar en su boveda
    @dev la funcion actualiza la boveda del usuario
    @dev la funcion actualiza el contador de depositos
    @dev la funcion emite un evento de deposito
    @dev la funcion revierte si el deposito hace que el usuario supere el maximo de su boveda
    */
   function _deposit(address user, address token, uint256 amount) internal {
        if (token == address(0)) { //Si es ETH
            uint256 usdValue = ethDepositValueInUSD(amount); //Obtengo el valor en USD del deposito
            if (usdValue + s_vaults[token][user] > BANK_CAP_USD) revert KipuBank_bankCapped(user, token); //Y verifico que no supere el maximo en USD
        } else { //Si no es ETH sigo el flujo normal
            if (!s_tokens[token]) revert KipuBank_nonExistentToken(token);
            if (amount + s_vaults[token][user] > BANK_CAP) revert KipuBank_bankCapped(user, token);
        }
        _updateVault(user, token, s_vaults[token][user] + amount);
        s_deposits += 1;
        emit KipuBank_deposit(user, token, amount);
    }

    /*
    @notice funcion que permite a un usuario depositar ETH en su boveda
    @dev la funcion llama a la funcion interna _deposit
    */
    function deposit() external payable {
        _deposit(msg.sender, address(0), msg.value);
    }

    /*
    @notice funcion que permite a un usuario depositar tokens ERC20 en su boveda
    @dev la funcion revierte si el deposito hace que el usuario supere el maximo de su boveda
    @dev la funcion transfiere los tokens del usuario al contrato
    */
    function depositToken(address token, uint256 amount) external {
        if (!s_tokens[token]) revert KipuBank_nonExistentToken(token);
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        _deposit(msg.sender, token, amount);
    }

    /*
    @notice funcion que permite a un usuario retirar fondos de su boveda
    @dev la funcion actualiza la boveda del usuario
    @dev la funcion actualiza el contador de retiros
    @dev la funcion emite un evento de retiro
    @dev la funcion revierte si el usuario quiere retirar mas fondos de los que posee
    @dev la funcion revierte si el usuario quiere retirar mas fondos de lo permitido por el banco
    @dev la funcion revierte si el la token no existe
    @dev la funcion revierte si la transferencia de fondos falla
    */
   function withdrawal(address token, uint256 quant) external nonReentrant {
        if (quant > s_vaults[token][msg.sender]) revert KipuBank_unsuficentFunds(msg.sender, token);
        if (token == address(0) && quant > i_maxWithdrawal) revert KipuBank_withdrawalCapped(msg.sender, token);
        if (!s_tokens[token] && token != address(0)) revert KipuBank_nonExistentToken(token);

        _updateVault(msg.sender, token, s_vaults[token][msg.sender] - quant);
        s_withdrawals += 1;

        if (token == address(0)){
            address payable recipient = payable(msg.sender);
            (bool success, ) = recipient.call{value: quant}("");
            if (!success) revert KipuBank_withdrawalFailed(msg.sender, token);
        } else {
            IERC20(token).safeTransfer(msg.sender, quant);
        }
         emit KipuBank_withdrawal(msg.sender, token, quant);
   }

    /*
    @notice funcion que permite a un usuario ver la cantidad total de retiros realizados
    @return uint256 cantidad total de retiros realizados
    */
    function viewWithdrawals() external view returns(uint256){
        return s_withdrawals;
    }

    /*
    @notice funcion que permite a un usuario ver la cantidad total de depositos realizados
    @return uint256 cantidad total de depositos realizados
    */
    function viewDeposits() external view returns(uint256){
        return s_deposits;
    }

    /*
    @notice funcion que permite a un usuario ver el saldo de su boveda para un token especifico
    @param token direccion del token a consultar, address(0) para ETH
    @dev la funcion revierte si el token no existe
    @return uint256 saldo actual de la boveda del usuario
    */
    function viewVault(address token) external view returns(uint256){
        if (!s_tokens[token] && token != address(0)) revert KipuBank_nonExistentToken(token);

        return s_vaults[token][msg.sender];
    }

    /*
    @notice funcion que permite actualizar la direccion del feed de Chainlink para el precio de ETH
    @param _feed direccion del nuevo feed de Chainlink
    @dev la funcion emite un evento de actualizacion del feed
    */
    function setFeed(address _feed) external onlyOwner {
        s_feed = AggregatorV3Interface(_feed);
        emit KipuBank_feedUpdated(_feed);
    }

    /*
    @notice funcion que obtiene el precio actual de ETH en USD desde el feed de Chainlink
    */
    function getLatestEthPrice() public view returns (int) {
        (
            , 
            int price,
            ,
            ,
            
        ) = s_feed.latestRoundData();
        return price;
    }

    /*
    @notice funcion que convierte una cantidad de ETH a su valor equivalente en USD
    @param ethAmount cantidad de ETH a convertir
    @dev la funcion utiliza el precio obtenido desde el feed de Chainlink
    */
    function ethDepositValueInUSD(uint256 ethAmount) internal view returns (uint256) {
    (, int256 ethPrice, , uint256 updateTime, ) = s_feed.latestRoundData();

    if (block.timestamp - updateTime > 1 hours) revert KipuBank_StalePrice();
    if (ethPrice <= 0) revert KipuBank_OracleError();

    return (ethAmount * uint256(ethPrice)) / 1e18;
    }

    /*
    @notice funcion que permite al owner agregar un token al banco
    @param token direccion del token a agregar
    @dev la funcion emite un evento de token agregado
    */
    function addToken(address token) external onlyOwner {
        s_tokens[token] = true;
        emit KipuBank_tokenAdded(token);
    }

    /*
    @notice funcion que permite al owner eliminar un token del banco
    @param token direccion del token a eliminar
    @dev la funcion emite un evento de token eliminado
    */
    function removeToken(address token) external onlyOwner {
        s_tokens[token] = false;
        emit KipuBank_tokenRemoved(token);
    }
}