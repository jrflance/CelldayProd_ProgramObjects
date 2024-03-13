--liquibase formatted sql

--changeset melissarios:213112 stripComments:false runOnChange:true endDelimiter:/
-- noqa: disable=all
/*================================================================================================================
      Author : Melissa Rios
 Create Date : 20240311
 Description : Pulls summary of the previous day's invoices for any given account id. Intended to be sent via ftp.
 ===============================================================================================================*/
-- noqa: enable=all
CREATE OR ALTER PROCEDURE [Report].[P_Report_Invoice_Summary]
    (
        @AccountID INT
    )
AS
BEGIN
    BEGIN TRY
        SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

        DECLARE
            @StartDate DATE = CASE
                WHEN DATENAME(WEEKDAY, GETDATE()) = 'Monday' THEN CAST(DATEADD(DAY, -3, GETDATE()) AS DATE)
                ELSE CAST(DATEADD(DAY, -1, GETDATE()) AS DATE)
            END

        IF OBJECT_ID('tempdb..#ListOfAccounts') IS NOT NULL
            BEGIN
                DROP TABLE #ListOfAccounts;
            END;

        CREATE TABLE #ListOfAccounts
        (AccountID INT);

        INSERT INTO #ListOfAccounts
        EXEC [Account].[P_Account_GetAccountList]
            @AccountID = @AccountID,
            @UserID = 1,
            @AccountTypeID = '2,5,6,11',
            @AccountStatusID = '0,1,2,3,4,5,6,7',
            @Simplified = 1

        INSERT INTO #ListOfAccounts
        (AccountID)
        VALUES (@AccountID)

        SELECT
            n.Account_ID,
            a.Account_Name,
            c.Address1,
            c.Address2,
            c.City,
            c.State,
            c.Zip,
            n.DateOrdered,
            n.DateFilled,
            'Invoice' AS Product,
            CASE
                WHEN n.OrderType_ID = 6 THEN 'Master Agent Commission'
                WHEN n.OrderType_ID = 5 THEN 'Merchant Invoice'
                ELSE oti.OrderType_Desc
            END AS [Description],
            n.Order_No AS InvoiceNumber,
            n.OrderTotal AS Amount
        FROM dbo.Order_No AS n
        JOIN dbo.OrderType_ID AS oti
            ON oti.OrderType_ID = n.OrderType_ID
        JOIN dbo.Account AS a
            ON a.Account_ID = n.Account_ID
        JOIN dbo.Customers AS c
            ON c.Customer_ID = a.Customer_ID
        WHERE
            n.Account_ID = @AccountID
            AND n.OrderType_ID IN (5, 6)
            AND n.Filled = 1
            AND n.Void = 0
            AND n.Process = 1
            AND n.DateDue >= @StartDate
            AND n.DateDue < CAST(GETDATE() AS DATE)

    END TRY
    BEGIN CATCH
        SELECT
            ERROR_NUMBER() AS ErrorNumber
            , ERROR_MESSAGE() AS ErrorMessage;
    END CATCH;

END

-- noqa: disable=all
/
