--liquibase formatted sql

--changeset NicolasGriesdorn:31f9b83b stripComments:false runOnChange:true

-- =============================================
--             :
--      Author : Nicolas Griesdorn
--             :
--     Created : 2024-02-26
--             :
-- Description : This report returns changes made to the credit limits of a Victra account.
--             :
--             :
--       Usage : EXEC [Report].[P_Report_CreditChangeHistory_Victra] 155536
--             :
-- =============================================
CREATE OR ALTER PROCEDURE [Report].[P_Report_CreditChangeHistory_Victra]
    (
        @SessionAccountId INT = 155536
    )
AS
BEGIN
    BEGIN TRY
        IF OBJECT_ID('tempdb..#ListOfAccounts') IS NOT NULL
            BEGIN
                DROP TABLE #ListOfAccounts;
            END;

        DECLARE @AccountID INT;


        CREATE TABLE #ListOfAccounts
        (AccountID INT);

        INSERT INTO #ListOfAccounts
        EXEC [Account].[P_Account_GetAccountList]
            @AccountID = @SessionAccountId,              -- int
            @UserID = 1,                          -- int
            @AccountTypeID = '2,5,6,8,11',             -- varchar(50)
            @AccountStatusID = '0,1,2,3,4,5,6,7', -- varchar(50)
            @Simplified = 1;

        SELECT
            al.[Account_ID],
            CONVERT(NVARCHAR(19), al.[LogDate], 120) AS [LogDate],
            ur.[UserName] AS [User Name],
            al.[UserName] AS [User ID],
            al.[Note] AS [Note]
        FROM [dbo].[Account_ActivityLog] AS al WITH (NOLOCK)
        JOIN #ListOfAccounts AS la WITH (NOLOCK)
            ON
                al.Account_ID = la.AccountID
                AND ISNUMERIC(la.AccountID) = 1
        JOIN Users AS ur WITH (NOLOCK)
            ON
                al.UserName = ur.User_ID
                AND ISNUMERIC(al.UserName) > 0
        WHERE al.LogDate >= DATEADD(D, -1, GETDATE())
        ORDER BY [LogDate];
    END TRY
    BEGIN CATCH

        SELECT
            ERROR_NUMBER() AS ErrorNumber,
            ERROR_MESSAGE() AS ErrorMessage;
    END CATCH;
END;
