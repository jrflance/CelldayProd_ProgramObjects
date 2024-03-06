--liquibase formatted sql
--changeset fserrano:f1bfff1c stripComments:false runOnChange:true endDelimiter:/
CREATE OR ALTER PROCEDURE [Report].[P_Report_Get_Account_Shipping_Details_for_TradeInBot]
    (
        @AccountID INT,
        @SessionAccountid INT
    )
AS
BEGIN
    BEGIN TRY

        SET NOCOUNT ON;

        IF @SessionAccountid <> 2
            BEGIN
                SELECT 'This account is not authorized to run this process.' AS [ERROR];
                RETURN;
            END;

        --declare @AccountID int = 28271
        SELECT
            a.Account_ID AS [AccountID],
            a.Account_name AS [AccountName],
            IIF(ship.FirstName = '', 'Vidapay', ship.FirstName) AS [FirstName],
            IIF(ship.LastName = '', 'Merchant', ship.LastName) AS [LastName],
            IIF(ship.Address1 = '', '7240 Muirfield Dr', ship.Address1) AS [Address],
            IIF(ship.Address1 = '', 'Ste 200', ship.Address2) AS [Address2],
            IIF(ship.Address1 = '', 'DUBLIN', ship.City) AS [City],
            IIF(ship.Address1 = '', 'OH', ship.State) AS [State],
            IIF(ship.Address1 = '', '43017', ship.Zip) AS [Postal Code]
        FROM account AS a
        LEFT JOIN customers AS ship
            ON ship.customer_id = a.shipto
        WHERE a.account_ID = @AccountID;

    END TRY
    BEGIN CATCH

        SELECT
            ERROR_NUMBER() AS ErrorNumber,
            ERROR_MESSAGE() AS ErrorMessage;
    END CATCH;
END;
-- noqa: disable=all
/
